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

# Many vast containers run as root with no `sudo` installed, so `| sudo bash`
# dies with "sudo: command not found". Use sudo only when it exists and we are
# not already root.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || { log "not root and no sudo -- cannot install packages"; exit 1; }
    SUDO="sudo"
fi

# --- swap -------------------------------------------------------------------
# The $6 droplet has 1 GiB and no swap. rclone walking a large tree was OOM-killed
# there at 651 MB RSS:
#   Out of memory: Killed process ... (rclone) anon-rss:651468kB
# Swap turns that from a hard kill into slow progress.
if [ "$(swapon --show --noheadings 2>/dev/null | wc -l)" -eq 0 ] && [ ! -e /swapfile ]; then
    log "no swap -- creating a 2G swapfile"
    $SUDO fallocate -l 2G /swapfile 2>/dev/null || $SUDO dd if=/dev/zero of=/swapfile bs=1M count=2048
    $SUDO chmod 600 /swapfile
    $SUDO mkswap /swapfile >/dev/null
    $SUDO swapon /swapfile
fi
log "swap: $(free -h | awk '/Swap:/{print $2" total, "$3" used"}')"

# --- rclone -----------------------------------------------------------------
if ! command -v rclone >/dev/null 2>&1; then
    log "installing rclone"
    command -v curl >/dev/null 2>&1 || { log "curl missing"; $SUDO apt-get update -qq && $SUDO apt-get install -y curl; }
    curl -fsSL https://rclone.org/install.sh | $SUDO bash
fi
log "rclone $(rclone version | head -1)"

# --- gh ---------------------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
    log "installing gh"
    (type -p wget >/dev/null || { $SUDO apt-get update -qq; $SUDO apt-get install -y wget; })
    $SUDO mkdir -p -m 755 /etc/apt/keyrings
    wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | $SUDO tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    $SUDO chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    $SUDO apt-get update -qq && $SUDO apt-get install -y gh
fi
command -v gh >/dev/null 2>&1 || { log "gh install failed -- install it manually, then re-run"; exit 1; }

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
