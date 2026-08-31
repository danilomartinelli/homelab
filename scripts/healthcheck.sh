#!/usr/bin/env bash
#
# Quick health check for the homelab host. Reports service status, disk
# usage, and whether the restic backup ran recently. Exits non-zero on
# any degraded condition so it can plug into a cron alert or uptime check.

set -euo pipefail

HOST="${1:-${HOMELAB_HOST:-kodo.witek.sh}}"
SSH_KEY="${HOMELAB_SSH_KEY:-${HOME}/.ssh/id_ed25519}"
SSH_TARGET="admin@${HOST}"

ssh -T -i "$SSH_KEY" -o IdentitiesOnly=yes -o ControlPath=none -o ConnectTimeout=10 \
  "$SSH_TARGET" bash --noprofile --norc -s <<'REMOTE'
  set -u
  failed=0

  printf '› Disk usage\n'
  df -h / | tail -1 | awk '{print "  " $5 " used on " $1}'

  printf '› Service status\n'
  for svc in sshd docker tailscaled uncloud hermes-chromium hermes; do
    if sudo systemctl is-active --quiet "$svc"; then
      printf '  ✓ %s\n' "$svc"
    else
      printf '  ✗ %s (down)\n' "$svc" >&2
      failed=1
    fi
  done

  printf '› Hermes container\n'
  health=$(sudo docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' hermes 2>/dev/null || true)
  if [ "$health" = healthy ]; then
    printf '  ✓ healthy\n'
  else
    printf '  ✗ %s\n' "${health:-missing}" >&2
    failed=1
  fi

  printf '› Backup coverage\n'
  if ! sudo kodo-backup-verify; then
    printf '  ✗ backup coverage verification failed\n' >&2
    failed=1
  fi

  printf '› Tailscale IP\n'
  tailscale ip -4 2>/dev/null | head -1 || {
    printf '  ✗ tailscale not up\n' >&2
    failed=1
  }

  result=$failed
  set +u
  exit "$result"
REMOTE
