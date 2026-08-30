#!/usr/bin/env bash
# LEG 1 -- run on the DigitalOcean jump host (Bangalore).
# Copies gdrive -> B2. Bytes stream through this box; nothing is staged on disk,
# so a 25 GB droplet is fine.
#
# gdrive is READ-ONLY here, enforced two ways:
#   1. the TOKEN is minted read-only:  rclone authorize "drive" --drive-scope=drive.readonly
#      Setting scope= in the config does NOT reduce an already-granted token's
#      permissions; only the grant at authorize time does.
#   2. this script uses `copy`, never `sync`.
# Nothing here can write to or delete from Google Drive.
#
# THE SOURCE IS REQUIRED. `gd:` is anchored at the Drive ROOT, which holds ~200
# unrelated folders (resumes, course downloads, Takeout). There is deliberately
# no default, and empty / "/" / "." are refused, so no invocation can sweep the
# whole Drive.
#
# Usage:
#   source ~/b2-secrets/b2env
#   ./bin/jump-gdrive-to-b2.sh --preset derisk    --dry-run
#   ./bin/jump-gdrive-to-b2.sh --preset derisk
#   ./bin/jump-gdrive-to-b2.sh --preset derisk-live \
#       --pacer 10ms --tpslimit 100 --transfers 32 --checkers 32
#   ./bin/jump-gdrive-to-b2.sh --preset all --pacer 10ms --tpslimit 100 --transfers 32 --checkers 32
#   ./bin/jump-gdrive-to-b2.sh --preset results
#   ./bin/jump-gdrive-to-b2.sh --preset metrics
#
# presets: all | results | metrics | derisk | derisk-live
#   all = every dir under vast-112 plus loose files (what the vast-utils
#         aliases upload); results/metrics are only 2 of those 9.
#   ./bin/jump-gdrive-to-b2.sh --src vast-112/results-torchray --dst results-torchray --per-dir
set -euo pipefail

: "${B2_BUCKET:?run: source ~/b2-secrets/b2env}"

# Matches the exclude already used by upload_bigfiles_other_ in
# vast-utils/gdrive_shortcuts.sh, so B2 mirrors what Drive actually holds.
EXCLUDE='{**/wandb,**.sw*,**/*.wandb}'

PRESET=""
SRC=""
DST=""
DRY=""
PER_DIR=""
DIRS_FROM=""
REVERSE=""
USE_MARKERS=""
TRANSFERS=8
CHECKERS=4
TPSLIMIT=12
# --max-backlog caps how many objects rclone queues between the lister and the
# transferrers. THIS is the memory knob: the OOM was ~500 MB of queued object
# metadata, not the 128 MiB of transfer buffers, so lowering --transfers alone
# would not have helped. Default 10000; 500 keeps the queue small.
BACKLOG=500
BUFSIZE=1M
# rclone's Drive backend has its OWN pacer, default 100ms between API calls =
# a hard 10 requests/sec ceiling regardless of --tpslimit. On a workload that
# is nothing but API calls, that default is the dominant cost.
PACER=100ms
LOGDIR="${LOGDIR:-$PWD/logs/jump}"

usage() {
    sed -n '2,26p' "$0" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --preset)     PRESET="$2"; shift ;;
        --src)        SRC="$2"; shift ;;
        --dst)        DST="$2"; shift ;;
        --dry-run)    DRY="--dry-run" ;;
        --per-dir)    PER_DIR="yes" ;;
        --dirs-from)  DIRS_FROM="$2"; shift ;;
        --reverse)    REVERSE="yes" ;;
        --use-markers) USE_MARKERS="yes" ;;
        --transfers)  TRANSFERS="$2"; shift ;;
        --checkers)   CHECKERS="$2"; shift ;;
        --max-backlog) BACKLOG="$2"; shift ;;
        --buffer-size) BUFSIZE="$2"; shift ;;
        --tpslimit)   TPSLIMIT="$2"; shift ;;
        --pacer)      PACER="$2"; shift ;;
        -h|--help)    usage ;;
        *) echo "unknown arg: $1" >&2; usage ;;
    esac
    shift
done

# Presets carry the measured Drive layout. The live corpus is under vast-112/
# (601 method dirs); the bare gd:results-torchray path is an older partial copy
# (393 dirs) whose uploader is commented out in vast-utils/gdrive_shortcuts.sh.
# B2 paths deliberately DROP the vast-112/ prefix so the archive mirrors the
# LOCAL layout -- which is also what leg 2 (source-local-to-b2.sh) writes.
case "$PRESET" in
    "")       ;;
    derisk)   # small, real subtree for the de-risk test: 10,000 tiny objects.
              # Lands under _derisk/ so it can be dropped wholesale.
              SRC="vast-112/results-torchray/cifar-10-grad_cam-vgg16"
              DST="_derisk/results-torchray/cifar-10-grad_cam-vgg16"
              PER_DIR="" ;;
    derisk-live)
              # Same shape -- 10,000 tiny objects -- but a DIFFERENT dir, so
              # Drive's listing for it is still cold and the timing is
              # comparable to the first derisk run. Writes to the FINAL
              # destination rather than _derisk/, so the bytes count as real
              # migration progress instead of being thrown away. That is safe
              # because it is a genuine corpus directory, not synthetic data.
              SRC="vast-112/results-torchray/cifar-10-gradient-vgg16"
              DST="results-torchray/cifar-10-gradient-vgg16"
              PER_DIR="" ;;
    results)  SRC="vast-112/results-torchray"
              DST="results-torchray"
              PER_DIR="yes" ;;
    metrics)  SRC="vast-112/metrics-torchray"
              DST="metrics-torchray"
              PER_DIR="yes" ;;
    all)      # EVERYTHING the vast-utils aliases upload: results-torchray and
              # metrics-torchray are only 2 of the 9 dirs under vast-112. The
              # rest -- condaenvs, dataset, evaluate-saliency-4, myhelp, todo,
              # todo2, vast-utils -- plus the loose instance_info.sh were not
              # covered by any earlier preset.
              # The vast-112/ prefix is still stripped on the B2 side, so the
              # archive mirrors the LOCAL layout and matches what leg 2 writes.
              SRC="vast-112"
              DST=""
              PER_DIR="yes" ;;
    *) echo "unknown preset: $PRESET (all|results|metrics|derisk|derisk-live)" >&2; exit 2 ;;
esac

[ -n "$SRC" ] || { echo "ERROR: --src or --preset is required" >&2; usage; }
case "$SRC" in
    ""|"/"|"."|"./"|"*")
        echo "ERROR: refusing source '$SRC' -- that is the whole Drive root" >&2
        exit 2 ;;
esac
# `all` deliberately sets DST="" (bucket root), so only an UNSET DST defaults.
DST="${DST-$SRC}"

mkdir -p "$LOGDIR"
log() { printf '[jump] %s\n' "$*" >&2; }

# -P renders progress on the TERMINAL. Without it, --log-file swallows the stats
# too and a long Drive enumeration looks like a dead prompt.
RCLONE_ARGS=(
    --links
    -P
    --transfers "$TRANSFERS" --checkers "$CHECKERS"
    --buffer-size "$BUFSIZE"
    --max-backlog "$BACKLOG"
    --tpslimit "$TPSLIMIT" --tpslimit-burst "$((TPSLIMIT * 2))"
    --drive-pacer-min-sleep "$PACER"
    --retries 3 --low-level-retries 20
    --exclude "$EXCLUDE"
    --stats 30s
)

log "source      gd:$SRC"
DEST_BASE="b2:$B2_BUCKET${DST:+/$DST}"
log "destination $DEST_BASE"
log "mode        $([ -n "$PER_DIR" ] && echo 'per-directory (resumable)' || echo 'single copy')"
log "tuning      transfers=$TRANSFERS checkers=$CHECKERS tpslimit=$TPSLIMIT pacer=$PACER"
log "memory      buffer-size=$BUFSIZE max-backlog=$BACKLOG"
[ -n "$DRY" ] && log "DRY RUN -- nothing will be written"

if [ -z "$PER_DIR" ]; then
    single_log="$LOGDIR/$(echo "$DST" | tr / _).log"
    log "log         $single_log"
    log "Drive enumeration is slow. Watch the Checks counter -- that is the"
    log "progress; Transferred stays at 0 B on a --dry-run by definition."
    rclone copy "gd:$SRC" "$DEST_BASE" $DRY "${RCLONE_ARGS[@]}" \
        --log-level INFO --log-file "$single_log"
    log "done. log: $single_log"
    exit 0
fi

# One copy per top-level dir, with a .done marker so a killed run resumes.
# Deliberately NOT --fast-list: rclone holds ~1 KB per object, so a whole-corpus
# listing wants GBs of RAM on a 1 GiB droplet, and B2 charges $0 for list calls.
if [ -n "$DIRS_FROM" ]; then
    if [ -n "$REVERSE" ]; then
        mapfile -t DIRS < <(tac "$DIRS_FROM")
    else
        mapfile -t DIRS < "$DIRS_FROM"
    fi
else
    log "listing dirs under gd:$SRC (slow on Drive -- not a hang)"
    if [ -n "$REVERSE" ]; then
        mapfile -t DIRS < <(rclone lsf --dirs-only --format p "gd:$SRC" | sed 's:/$::' | sort -r)
    else
        mapfile -t DIRS < <(rclone lsf --dirs-only --format p "gd:$SRC" | sed 's:/$::' | sort)
    fi
fi
log "${#DIRS[@]} dirs to process, transfers=$TRANSFERS"

for d in "${DIRS[@]}"; do
    [ -n "$d" ] || continue
    # OFF by default. a-on-drive still receives uploads, so a directory marked
    # "done" would permanently skip files added to it later. --use-markers is
    # for a one-shot bulk pass where re-listing Drive dominates the cost and
    # you are accepting that trade knowingly.
    marker="$LOGDIR/$(echo "$DST/$d" | tr / _).done"
    if [ -n "$USE_MARKERS" ] && [ -f "$marker" ]; then
        log "SKIP (marker present): $d"
        continue
    fi
    log "=== $d"
    rclone copy "gd:$SRC/$d" "$DEST_BASE/$d" $DRY "${RCLONE_ARGS[@]}" \
        --log-level INFO --log-file "$LOGDIR/$(echo "$DST/$d" | tr / _).log"
    [ -z "$DRY" ] && [ -n "$USE_MARKERS" ] && touch "$marker"
done

# The loop above only walks directories, so files sitting directly at the source
# root would be silently skipped -- vast-112/instance_info.sh is one.
loose_marker="$LOGDIR/$(echo "${DST:-root}" | tr / _)_LOOSEFILES.done"
if [ -z "$USE_MARKERS" ] || [ ! -f "$loose_marker" ]; then
    log "=== loose files at gd:$SRC (max-depth 1)"
    rclone copy "gd:$SRC" "$DEST_BASE" $DRY "${RCLONE_ARGS[@]}" \
        --max-depth 1 \
        --log-level INFO --log-file "$LOGDIR/$(echo "${DST:-root}" | tr / _)_loose.log"
    [ -z "$DRY" ] && [ -n "$USE_MARKERS" ] && touch "$loose_marker"
fi

log "done. logs in $LOGDIR"
