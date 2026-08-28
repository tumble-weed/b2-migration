#!/usr/bin/env bash
# One-time setup on any box (DigitalOcean, vast, anywhere).
# Installs rclone, fetches the PRIVATE secrets repo, checks the remotes work.
#
# Usage:   ./bin/bootstrap.sh
# Then:    source ~/b2-secrets/b2env
set -euo pipefail

SECRETS_REPO="${B2_SECRETS_REPO:-tumble-weed/b2-secrets}"
SECRETS_DIR="${B2_SECRETS_DIR:-$HOME/b2-secrets}"

case "${1:-}" in
    --no-gdrive) SKIP_GDRIVE=1 ;;
    "")          ;;
    *) echo "usage: $0 [--no-gdrive]" >&2; exit 2 ;;
esac

log() { printf '[bootstrap] %s\n' "$*" >&2; }

# --- rclone -----------------------------------------------------------------
if ! command -v rclone >/dev/null 2>&1; then
    log "installing rclone"
    curl -fsSL https://rclone.org/install.sh | sudo bash
fi
log "rclone $(rclone version | head -1)"

# --- gh ---------------------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
    log "installing gh"
    (type -p wget >/dev/null || sudo apt-get install -y wget)
    sudo mkdir -p -m 755 /etc/apt/keyrings
    wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update && sudo apt-get install -y gh
fi

# Device-code flow: you type a short code on your own machine.
# Do NOT copy a long-lived PAT onto a throwaway box.
if ! gh auth status >/dev/null 2>&1; then
    log "not logged in to GitHub -- starting device-code login"
    gh auth login
fi

# --- secrets ----------------------------------------------------------------
# Clone HEAD, deliberately not a submodule: rotating a key must be a single
# commit in the secrets repo, with no pointer to bump here.
if [ -d "$SECRETS_DIR/.git" ]; then
    log "updating $SECRETS_DIR"
    git -C "$SECRETS_DIR" pull --ff-only
else
    log "cloning $SECRETS_REPO -> $SECRETS_DIR"
    gh repo clone "$SECRETS_REPO" "$SECRETS_DIR"
fi
chmod 700 "$SECRETS_DIR"
chmod 600 "$SECRETS_DIR/b2env"

# --- verify -----------------------------------------------------------------
# shellcheck source=/dev/null
source "$SECRETS_DIR/b2env"
# NOT `rclone about` -- B2 buckets do not implement it, so it fails even on a
# perfectly good setup ("doesn't support about"). A shallow list proves the key
# and bucket without needing quota support. An empty bucket lists nothing and
# still exits 0, which is the expected state before the first upload.
log "B2 -- listing b2:${B2_BUCKET:?B2_BUCKET not set in b2env}"
rclone lsf --max-depth 1 b2:"$B2_BUCKET" >/dev/null || {
    log "FAILED to reach b2:$B2_BUCKET -- check the key and bucket name"; exit 1; }
log "  ok"
# Drive is only needed on the jump host. A verify box restores FROM B2 and never
# touches Drive, so a Drive failure there must not abort setup.
#   ./bin/bootstrap.sh --no-gdrive      skip the probe entirely
if [ -n "${SKIP_GDRIVE:-}" ]; then
    log "gdrive check skipped (--no-gdrive)"
else
    # Verify against a SMALL, known path. Do NOT list gd: itself -- that is the
    # Drive root, ~200 unrelated folders, and enumerating it takes minutes.
    GD_PROBE="${GD_PROBE:-vast-112/results-torchray}"
    log "gdrive (read-only token) -- probing gd:$GD_PROBE"
    if rclone lsjson --stat gd:"$GD_PROBE" >/dev/null 2>&1; then
        log "  ok"
    else
        log "  WARNING: could not reach gd:$GD_PROBE"
        log "  Only the jump host needs Drive. If this is a verify or upload box,"
        log "  ignore it, or re-run with --no-gdrive."
        log "  If this IS the jump host, the usual cause is a token minted under a"
        log "  different client_id than the one in b2env -- see bin/authorize-drive.sh"
    fi
fi

cat <<MSG

[bootstrap] ready. In every new shell, first run:

    source $SECRETS_DIR/b2env

MSG
