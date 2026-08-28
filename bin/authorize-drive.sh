#!/usr/bin/env bash
# Mint a read-only Drive token under YOUR OAuth client -- and refuse to do it
# under rclone's shared one by accident.
#
# The failure this exists to prevent: running
#     rclone authorize "drive" "$RCLONE_CONFIG_GD_CLIENT_ID" ...
# in a shell where b2env was never sourced. The variables expand to empty,
# rclone silently falls back to its own built-in client, and you get a token
# that LOOKS fine and works for about an hour -- until the access token expires
# and the refresh fails with "unauthorized_client", because the token's issuer
# no longer matches the client_id in b2env.
#
# Usage:
#   source ~/b2-secrets/b2env
#   ./bin/authorize-drive.sh
set -euo pipefail

log() { printf '[authorize] %s\n' "$*" >&2; }

: "${RCLONE_CONFIG_GD_CLIENT_ID:?not set -- run: source ~/b2-secrets/b2env}"
: "${RCLONE_CONFIG_GD_CLIENT_SECRET:?not set -- run: source ~/b2-secrets/b2env}"

case "$RCLONE_CONFIG_GD_CLIENT_ID" in
    *.apps.googleusercontent.com) ;;
    *) log "client_id does not look like a Google client id -- refusing"; exit 2 ;;
esac

log "client_id ...${RCLONE_CONFIG_GD_CLIENT_ID: -32}"
log "scope     drive.readonly"
log ""
log "This box is probably headless. From your laptop:"
log "  ssh -N -L 53682:localhost:53682 -p <port> root@<host>"
log "then open the URL printed below in the laptop browser."
log ""

rclone authorize "drive" \
    "$RCLONE_CONFIG_GD_CLIENT_ID" \
    "$RCLONE_CONFIG_GD_CLIENT_SECRET" \
    --drive-scope=drive.readonly

cat <<'MSG'

[authorize] Paste the blob above into b2env:

    ./bin/fill-b2env.py --only RCLONE_CONFIG_GD_TOKEN

Then PROVE the pair works before trusting it -- a fresh access token hides a
mismatch for about an hour:

    source ./b2env
    rclone lsf --dirs-only --max-depth 1 gd:vast-112

MSG
