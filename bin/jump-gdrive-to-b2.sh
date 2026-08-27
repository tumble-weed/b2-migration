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
#   ./bin/jump-gdrive-to-b2.sh --preset results
#   ./bin/jump-gdrive-to-b2.sh --preset metrics
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
TRANSFERS=16
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
        --transfers)  TRANSFERS="$2"; shift ;;
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
    derisk)   # small, real subtree for the de-risk test: 10,000 tiny objects
              SRC="vast-112/results-torchray/cifar-10-grad_cam-vgg16"
              DST="_derisk/results-torchray/cifar-10-grad_cam-vgg16"
              PER_DIR="" ;;
    results)  SRC="vast-112/results-torchray"
              DST="results-torchray"
              PER_DIR="yes" ;;
    metrics)  SRC="vast-112/metrics-torchray"
              DST="metrics-torchray"
              PER_DIR="yes" ;;
    *) echo "unknown preset: $PRESET (derisk|results|metrics)" >&2; exit 2 ;;
esac

[ -n "$SRC" ] || { echo "ERROR: --src or --preset is required" >&2; usage; }
case "$SRC" in
    ""|"/"|"."|"./"|"*")
        echo "ERROR: refusing source '$SRC' -- that is the whole Drive root" >&2
        exit 2 ;;
esac
DST="${DST:-$SRC}"

mkdir -p "$LOGDIR"
log() { printf '[jump] %s\n' "$*" >&2; }

# -P renders progress on the TERMINAL. Without it, --log-file swallows the stats
# too and a long Drive enumeration looks like a dead prompt.
RCLONE_ARGS=(
    --links
    -P
    --transfers "$TRANSFERS" --checkers 8
    --buffer-size 4M
    --tpslimit 12 --tpslimit-burst 24
    --retries 3 --low-level-retries 20
    --exclude "$EXCLUDE"
    --stats 30s
)

log "source      gd:$SRC"
log "destination b2:$B2_BUCKET/$DST"
log "mode        $([ -n "$PER_DIR" ] && echo 'per-directory (resumable)' || echo 'single copy')"
[ -n "$DRY" ] && log "DRY RUN -- nothing will be written"

if [ -z "$PER_DIR" ]; then
    single_log="$LOGDIR/$(echo "$DST" | tr / _).log"
    log "log         $single_log"
    log "Drive enumeration is slow. Watch the Checks counter -- that is the"
    log "progress; Transferred stays at 0 B on a --dry-run by definition."
    rclone copy "gd:$SRC" "b2:$B2_BUCKET/$DST" $DRY "${RCLONE_ARGS[@]}" \
        --log-level INFO --log-file "$single_log"
    log "done. log: $single_log"
    exit 0
fi

# One copy per top-level dir, with a .done marker so a killed run resumes.
# Deliberately NOT --fast-list: rclone holds ~1 KB per object, so a whole-corpus
# listing wants GBs of RAM on a 1 GiB droplet, and B2 charges $0 for list calls.
if [ -n "$DIRS_FROM" ]; then
    mapfile -t DIRS < "$DIRS_FROM"
else
    log "listing dirs under gd:$SRC (slow on Drive -- not a hang)"
    mapfile -t DIRS < <(rclone lsf --dirs-only --format p "gd:$SRC" | sed 's:/$::')
fi
log "${#DIRS[@]} dirs to process, transfers=$TRANSFERS"

for d in "${DIRS[@]}"; do
    [ -n "$d" ] || continue
    marker="$LOGDIR/$(echo "$DST/$d" | tr / _).done"
    if [ -f "$marker" ]; then
        log "SKIP (already done): $d"
        continue
    fi
    log "=== $d"
    rclone copy "gd:$SRC/$d" "b2:$B2_BUCKET/$DST/$d" $DRY "${RCLONE_ARGS[@]}" \
        --log-level INFO --log-file "$LOGDIR/$(echo "$DST/$d" | tr / _).log"
    [ -z "$DRY" ] && touch "$marker"
done

log "done. logs in $LOGDIR"
