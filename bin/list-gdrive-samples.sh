#!/usr/bin/env bash
# Depth-2 listing of the Drive corpus: which <method>/<sample>/ dirs exist.
#
# WHY depth 2 and not a full listing. Drive has no recursive list, so rclone
# issues one query per directory. The corpus is one directory per sample --
# 3,939,217 of them -- and descending into all of them runs at ~4 dirs/sec:
# roughly eleven days. Listing one level down inside each method dir is PAGED
# instead (1,000 entries per call), measured at ~130 dirs/sec, so the whole
# corpus is ~8 hours.
#
# What this buys: the exact set of sample dirs Drive holds, so the corpus box
# can upload only the gap instead of racing the droplet for the same files.
#
# Blind spot, accepted deliberately: this proves a sample DIR exists, not that
# every file inside it does. 97.4% of sample dirs hold exactly one file, so
# dir-presence is file-presence for almost all of the corpus. The residue is
# caught by the final full sweep.
#
# Resumable: one output file per method dir, skipped if already present. Safe
# to kill and re-run.
#
# Usage:
#   source ~/b2-secrets/b2env
#   ./bin/list-gdrive-samples.sh                       # results-torchray
#   ./bin/list-gdrive-samples.sh --tpslimit 40         # faster, more 403 risk
#   ./bin/list-gdrive-samples.sh --src vast-112/metrics-torchray
set -euo pipefail

SRC="vast-112/results-torchray"
TPSLIMIT=20
OUTDIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --src)       SRC="$2"; shift ;;
        --tpslimit)  TPSLIMIT="$2"; shift ;;
        --out)       OUTDIR="$2"; shift ;;
        -h|--help)   sed -n '2,28p' "$0" >&2; exit 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$SRC" in
    ""|"/"|"."|"./") echo "ERROR: refusing source '$SRC'" >&2; exit 2 ;;
esac

# Reads Drive only -- no B2 involved, so no B2_BUCKET needed.
: "${RCLONE_CONFIG_GD_TOKEN:?run: source ~/b2-secrets/b2env}"

OUTDIR="${OUTDIR:-$PWD/manifests/gdrive_samples/$(echo "$SRC" | tr / _)}"
mkdir -p "$OUTDIR"
log() { printf '[list] %s\n' "$*" >&2; }

log "source     gd:$SRC"
log "output     $OUTDIR"
log "tpslimit   $TPSLIMIT"

# One query, paged: the method dirs.
methods_file="$OUTDIR/_methods.txt"
if [ ! -s "$methods_file" ]; then
    log "listing method dirs"
    rclone lsf --dirs-only --format p "gd:$SRC" --tpslimit "$TPSLIMIT" \
        | sed 's:/$::' | sort > "$methods_file"
fi
total=$(wc -l < "$methods_file")
log "$total method dirs"

i=0
while IFS= read -r m; do
    [ -n "$m" ] || continue
    i=$((i + 1))
    out="$OUTDIR/$(echo "$m" | tr / _).txt"
    if [ -s "$out" ]; then
        log "[$i/$total] SKIP $m"
        continue
    fi
    log "[$i/$total] $m"
    # Write to .part then rename, so a killed run never leaves a short file
    # that the skip-check above would trust.
    rclone lsf --dirs-only --format p "gd:$SRC/$m" --tpslimit "$TPSLIMIT" \
        | sed 's:/$::' | sed "s:^:$m/:" > "$out.part"
    mv "$out.part" "$out"
done < "$methods_file"

combined="$OUTDIR/../$(echo "$SRC" | tr / _)_samples.txt"
log "combining -> $combined"
cat "$OUTDIR"/*.txt \
    | grep -v '^$' \
    | sort -u > "$combined.part"
mv "$combined.part" "$combined"
log "done. $(wc -l < "$combined") sample dirs on Drive"
log "manifest: $combined"
