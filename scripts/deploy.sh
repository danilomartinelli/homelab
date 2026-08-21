#!/usr/bin/env bash
# Deploy the exact origin/main revision to kodo using the Git checkout at
# /etc/homelab. The first checkout migration is intentionally a separate,
# one-time operation; this script refuses to overwrite a materialised tree.

set -euo pipefail

HOST="${1:-${HOMELAB_HOST:-kodo.witek.sh}}"
REPO_DIR="${HOMELAB_REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SSH_KEY="${HOMELAB_SSH_KEY:-${HOME}/.ssh/id_ed25519}"
REMOTE="admin@${HOST}"
SSH=(ssh -i "$SSH_KEY" -o IdentitiesOnly=yes -o ControlPath=none -o ConnectTimeout=10)

log() { printf '› %s\n' "$*"; }
ok()  { printf '✓ %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

cd "$REPO_DIR"

test -r "$SSH_KEY" || die "SSH key is not readable: $SSH_KEY"
test "$(git branch --show-current)" = main || die "deploys must run from main"
test -z "$(git status --porcelain)" || die "the local worktree is not clean"

log "Checking that local main is published"
git fetch origin main
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" || \
  die "local main and origin/main differ; publish or reconcile before deploying"

log "Fast-forwarding /etc/homelab to origin/main"
"${SSH[@]}" "$REMOTE" 'set -euo pipefail
  sudo test -d /etc/homelab/.git || {
    echo "error: /etc/homelab is not a Git checkout; run the documented one-time migration" >&2
    exit 1
  }
  test -z "$(sudo git -C /etc/homelab status --porcelain)" || {
    echo "error: /etc/homelab has local changes" >&2
    sudo git -C /etc/homelab status --short >&2
    exit 1
  }
  sudo git -C /etc/homelab fetch origin main --prune
  sudo git -C /etc/homelab checkout main
  sudo git -C /etc/homelab merge --ff-only origin/main
'

log "Building and comparing the new closure"
"${SSH[@]}" "$REMOTE" 'set -euo pipefail
  cd /etc/homelab
  sudo nixos-rebuild build --flake .#kodo
  echo "systemd units:"
  diff -u \
    <(find /run/current-system/etc/systemd/system -maxdepth 1 -printf "%f\n" | sort) \
    <(find result/etc/systemd/system -maxdepth 1 -printf "%f\n" | sort) || true
  echo "multi-user wants:"
  diff -u \
    <(find /run/current-system/etc/systemd/system/multi-user.target.wants -maxdepth 1 -printf "%f\n" | sort) \
    <(find result/etc/systemd/system/multi-user.target.wants -maxdepth 1 -printf "%f\n" | sort) || true
  echo "kernel parameters:"
  diff -u /run/current-system/kernel-params result/kernel-params || true
'

log "Activating the candidate without changing the boot default"
"${SSH[@]}" "$REMOTE" 'cd /etc/homelab && sudo nixos-rebuild test --flake .#kodo'

log "Verifying SSH from a new connection"
"${SSH[@]}" "$REMOTE" 'sudo systemctl is-active sshd docker uncloudd'

log "Setting the tested generation as the boot default"
"${SSH[@]}" "$REMOTE" 'cd /etc/homelab && sudo nixos-rebuild boot --flake .#kodo'

log "Rebooting $HOST"
"${SSH[@]}" "$REMOTE" 'sudo systemctl reboot' || true

log "Waiting for a fresh SSH connection"
for _ in $(seq 1 60); do
  if "${SSH[@]}" "$REMOTE" true 2>/dev/null; then
    break
  fi
  sleep 5
done
"${SSH[@]}" "$REMOTE" true 2>/dev/null || die "host did not return after reboot"

log "Running post-reboot health checks"
"${SSH[@]}" "$REMOTE" 'set -euo pipefail
  sudo systemctl is-active sshd docker uncloudd hermes-chromium hermes
  sudo docker inspect --format "hermes={{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}" hermes
  test "$(sudo git -C /etc/homelab rev-parse HEAD)" = "$(sudo git -C /etc/homelab rev-parse origin/main)"
  printf "generation=%s\n" "$(readlink /run/current-system)"
'

ok "deploy complete on $HOST"
