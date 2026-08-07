#!/usr/bin/env bash
#
# Apply the latest homelab flake to a remote NixOS host via SSH. Requires
# the host to be reachable on its Tailscale hostname (or fallback IP).
#
# Usage:
#   scripts/deploy.sh [HOST]
#
# HOST defaults to homelab (resolved via Tailscale MagicDNS).

set -euo pipefail

HOST="${1:-${HOMELAB_HOST:-homelab}}"
DOTFILES_DIR="${HOMELAB_REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

cd "$DOTFILES_DIR"

log() { printf '› %s\n' "$*"; }
ok()  { printf '✓ %s\n' "$*"; }

log "Pushing latest changes to $HOST"
git push origin main 2>/dev/null || true  # optional; the remote is a git clone

log "Applying flake to $HOST"
ssh -o ConnectTimeout=10 "admin@${HOST}" \
  "cd /etc/homelab && git pull --ff-only && sudo nixos-rebuild switch --flake .#homelab"

ok "deploy complete on $HOST"
