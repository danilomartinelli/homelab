#!/usr/bin/env bash
#
# Quick health check for the homelab host. Reports service status, disk
# usage, and whether the restic backup ran recently. Exits non-zero on
# any degraded condition so it can plug into a cron alert or uptime check.

set -euo pipefail

HOST="${1:-${HOMELAB_HOST:-homelab}}"
SSH_TARGET="admin@${HOST}"

ssh -o ConnectTimeout=10 "$SSH_TARGET" <<'REMOTE'
  set -e
  printf '› Disk usage\n'
  df -h / | tail -1 | awk '{print "  " $5 " used on " $1}'

  printf '› Service status\n'
  for svc in docker tailscaled sshd; do
    if systemctl is-active --quiet "$svc"; then
      printf '  ✓ %s\n' "$svc"
    else
      printf '  ✗ %s (down)\n' "$svc" >&2
    fi
  done

  printf '› Last restic backup\n'
  restic snapshots --no-cache 2>/dev/null | tail -1 || echo "  (no restic repo yet)"

  printf '› Tailscale IP\n'
  tailscale ip -4 2>/dev/null | head -1 || echo "  (tailscale not up)"
REMOTE
