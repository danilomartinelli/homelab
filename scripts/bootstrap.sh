#!/usr/bin/env bash
#
# First-boot bootstrap for a fresh NixOS VPS. Run this once on the server
# from a root shell reachable over the public internet (Tailscale is not
# yet up). After it finishes, the only ingress is via Tailscale.
#
# Idempotent: safe to re-run.

set -euo pipefail

DOTFILES_REPO="${HOMELAB_REPO:-https://github.com/danilomartinelli/homelab.git}"
TARGET_DIR="/etc/homelab"

log()  { printf '› %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "bootstrap must run as root"

if ! command -v git >/dev/null 2>&1; then
  fail "git is missing — install it before running bootstrap"
fi

if [ ! -d "$TARGET_DIR/.git" ]; then
  log "Cloning $DOTFILES_REPO to $TARGET_DIR"
  git clone "$DOTFILES_REPO" "$TARGET_DIR"
else
  log "$TARGET_DIR already cloned; pulling"
  (cd "$TARGET_DIR" && git pull --ff-only)
fi

cd "$TARGET_DIR"

# 1. Make sure the host has the nix flakes experimental feature.
log "Enabling flakes + nix-command"
mkdir -p /etc/nix
cat >/etc/nix/nix.conf <<'EOF'
experimental-features = nix-command flakes
auto-optimise-store = true
EOF

# 2. Create the deploy user if it doesn't exist.
if ! id -u deploy >/dev/null 2>&1; then
  log "Creating deploy user"
  useradd -m -d /var/lib/homelab -s /bin/bash deploy
  mkdir -p /var/lib/homelab
  chown -R deploy:deploy /var/lib/homelab
else
  ok "deploy user exists"
fi

# 3. The user fills in secrets/.env.example → secrets/<file>, encrypts with
#    `sops --encrypt --in-place secrets/<file>`, then runs the switch step.
if [ ! -f "$TARGET_DIR/secrets/services.yaml" ]; then
  warn "secrets/services.yaml missing — sops-encrypted secrets must exist before 'nixos-rebuild switch'"
  warn "Generate an age key, edit .sops.yaml, then run:"
  warn "  sops secrets/services.yaml"
fi

# 4. Switch.
log "Running nixos-rebuild switch (this can take a few minutes)"
nixos-rebuild switch --flake .#homelab

ok "bootstrap complete. Verify with:"
echo "    systemctl status tailscaled docker"
echo "    tailscale up"
echo "    ssh admin@homelab.tail<hash>.ts.net"
