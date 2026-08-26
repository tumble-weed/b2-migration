#!/usr/bin/env bash
# LEG 1 -- run on the DigitalOcean jump host (Bangalore).
# Copies gdrive -> B2. Bytes stream through this box; nothing is staged on disk,
# so a 25 GB droplet is fine.
#
# gdrive is READ-ONLY here: the secrets repo pins the remote to
# scope=drive.readonly, and this script uses `copy`, never `sync`.
# Nothing in this repo can write to or delete from Google Drive.
#
# Usage:
#   source ~/b2-secrets/b2env
#   ./bin/jump-gdrive-to-b2.sh                 # all dirs under $GD_ROOT
#   ./bin/jump-gdrive-to-b2.sh --dry-run
#   ./bin/jump-gdrive-to-b2.sh --dirs-from dirs.txt
#   ./bin/jump-gdrive-to-b2.sh --transfers 32  # if RAM allows
set -euo pipefail

: "${B2_BUCKET:?run: source ~/b2-secrets/b2env}"
: "${GD_ROOT:?run: source ~/b2-secrets/b2env}"

DRY=""
DIRS_FROM=""
TRANSFERS=16
LOGDIR="${LOGDIR:-$PWD/logs/jump}"

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)    DRY="--dry-run" ;;
        --dirs-from)  DIRS_FROM="$2"; shift ;;
        --transfers)  TRANSFERS="$2"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$LOGDIR"
log() { printf '[jump] %s\n' "$*" >&2; }

# One sync per top-level dir. Deliberately NOT --fast-list: on a 1 GiB droplet a
# whole-corpus listing would need GBs of RAM, and B2 charges $0 for list calls,
# so there is nothing to save by batching them.
if [ -n "$DIRS_FROM" ]; then
    mapfile -t DIRS < "$DIRS_FROM"
else
    log "listing top-level dirs under gd:$GD_ROOT"
    mapfile -t DIRS < <(rclone lsf --dirs-only --format p "gd:$GD_ROOT" | sed 's:/$::')
fi
log "${#DIRS[@]} dirs to process, transfers=$TRANSFERS"

for d in "${DIRS[@]}"; do
    [ -n "$d" ] || continue
    marker="$LOGDIR/${d//\//_}.done"
    if [ -f "$marker" ]; then
        log "SKIP (already done): $d"
        continue
    fi
    log "=== $d"
    rclone copy "gd:$GD_ROOT/$d" "b2:$B2_BUCKET/$GD_ROOT/$d" \
        $DRY \
        --links \
        --transfers "$TRANSFERS" --checkers 8 \
        --buffer-size 4M \
        --tpslimit 12 --tpslimit-burst 24 \
        --retries 3 --low-level-retries 20 \
        --stats 30s --stats-one-line \
        --log-level INFO --log-file "$LOGDIR/${d//\//_}.log"
    if [ -z "$DRY" ]; then
        touch "$marker"
    fi
done

log "done. logs in $LOGDIR"
