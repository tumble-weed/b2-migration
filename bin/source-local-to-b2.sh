#!/usr/bin/env bash
# LEG 2 -- run on the vast box that HOLDS the corpus.
# Fills in whatever leg 1 could not get from gdrive. Because B2 already holds
# most files by then, rclone computes the delta itself -- no listing pass, no
# hand-built delta file.
#
# Compare criterion is rclone's DEFAULT (size + mtime), matching the flow
# already used for this box -> gdrive. --checksum was considered and not
# adopted; if a run starts transferring far more than expected, that is visible
# in the live stats within a minute.
#
# Usage:
#   source ~/b2-secrets/b2env
#   ./bin/source-local-to-b2.sh --src /data/bigfiles/other/results-torchray
#   ./bin/source-local-to-b2.sh --src ... --dry-run
set -euo pipefail

: "${B2_BUCKET:?run: source ~/b2-secrets/b2env}"

SRC=""
DRY=""
TRANSFERS=8
LOGDIR="${LOGDIR:-$PWD/logs/source}"

while [ $# -gt 0 ]; do
    case "$1" in
        --src)       SRC="$2"; shift ;;
        --dry-run)   DRY="--dry-run" ;;
        --transfers) TRANSFERS="$2"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$SRC" ] || { echo "--src is required" >&2; exit 2; }
[ -d "$SRC" ] || { echo "--src does not exist: $SRC" >&2; exit 2; }

mkdir -p "$LOGDIR"
name="$(basename "$SRC")"
printf '[source] %s -> b2:%s/%s\n' "$SRC" "$B2_BUCKET" "$name" >&2

# --links records each symlink as a .rclonelink file instead of following it.
# The corpus symlinks are relative and point at a sibling tree, so both trees
# must be uploaded and later restored under the same parent.
rclone copy "$SRC" "b2:$B2_BUCKET/$name" \
    $DRY \
    --links \
    --transfers "$TRANSFERS" --checkers 8 \
    --buffer-size 4M \
    --retries 3 --low-level-retries 20 \
    --stats 30s --stats-one-line \
    --log-level INFO --log-file "$LOGDIR/$name.log"

printf '[source] done. log: %s/%s.log\n' "$LOGDIR" "$name" >&2
