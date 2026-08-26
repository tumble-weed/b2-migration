#!/usr/bin/env bash
# One-time setup on any box (DigitalOcean, vast, anywhere).
# Installs rclone, fetches the PRIVATE secrets repo, checks the remotes work.
#
# Usage:   ./bin/bootstrap.sh
# Then:    source ~/b2-secrets/b2env
set -euo pipefail

SECRETS_REPO="${B2_SECRETS_REPO:-tumble-weed/b2-secrets}"
SECRETS_DIR="${B2_SECRETS_DIR:-$HOME/b2-secrets}"

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
log "B2 account:"
rclone about b2:"${B2_BUCKET:?B2_BUCKET not set in b2env}" || {
    log "FAILED to reach b2:$B2_BUCKET -- check the key and bucket name"; exit 1; }
log "gdrive (read-only token, anchored at root_folder_id):"
rclone lsd gd:"${GD_SUBPATH:-}" | head -5

cat <<MSG

[bootstrap] ready. In every new shell, first run:

    source $SECRETS_DIR/b2env

MSG
