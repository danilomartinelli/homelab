#!/usr/bin/env bash
#
# Host adapter for the rollout module. It is installed by Nix so the service
# and recovery facts checked here live beside the declarations that provide
# them, rather than being repeated in local SSH callers.

set -euo pipefail

BACKUP_VERIFY_COMMAND="${HOMELAB_BACKUP_VERIFY_COMMAND:-/run/current-system/sw/bin/kodo-backup-verify}"

usage() {
	printf 'usage: homelab-rollout-check --phase test|reboot|healthcheck\n' >&2
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -n "$BACKUP_VERIFY_COMMAND" ] || die "HOMELAB_BACKUP_VERIFY_COMMAND cannot be empty"
[ "$#" -eq 2 ] && [ "$1" = --phase ] || {
	usage
	exit 2
}

PHASE="$2"
case "$PHASE" in
test | reboot | healthcheck) ;;
*)
	usage
	exit 2
	;;
esac

check_service() {
	local service="$1"

	systemctl is-active --quiet "$service" || {
		printf '  ✗ %s (down)\n' "$service" >&2
		return 1
	}
	printf '  ✓ %s\n' "$service"
}

check_services() {
	local failed=0 service

	for service in "$@"; do
		check_service "$service" || failed=1
	done
	return "$failed"
}

check_hermes() {
	local health

	health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' hermes 2>/dev/null || true)"
	[ "$health" = healthy ] || {
		printf '  ✗ %s\n' "${health:-missing}" >&2
		return 1
	}
	printf '  ✓ healthy\n'
}

check_hermes_configuration() {
	local failed=0

	[ "$(docker exec hermes hermes config get stt.provider)" = local ] || {
		printf '  ✗ Hermes STT provider is not local\n' >&2
		failed=1
	}
	[ "$(docker exec hermes hermes config get stt.language)" = pt ] || {
		printf '  ✗ Hermes STT language is not pt\n' >&2
		failed=1
	}
	[ "$failed" -eq 0 ] || return "$failed"
	printf '  ✓ STT policy local/pt\n'
}

check_rollout() {
	local services=(sshd docker uncloud)
	local failed=0

	[ "$PHASE" = test ] && {
		printf '› Rollout service status\n'
		check_services "${services[@]}" || failed=1
		return "$failed"
	}

	services+=(hermes-chromium hermes)
	printf '› Rollout service status\n'
	check_services "${services[@]}" || failed=1
	printf '› Hermes container\n'
	check_hermes || failed=1
	printf '› Hermes policy\n'
	check_hermes_configuration || failed=1
	return "$failed"
}

check_disk() {
	printf '› Disk usage\n'
	df -hP / | awk 'NR == 2 { print "  " $5 " used on " $1 }'
}

check_backup() {
	local status

	printf '› Backup coverage\n'
	if "$BACKUP_VERIFY_COMMAND"; then
		return 0
	else
		status=$?
	fi
	printf '  ✗ declared backup coverage verification failed (exit %s)\n' "$status" >&2
	return "$status"
}

check_tailscale() {
	local ip

	printf '› Tailscale IP\n'
	ip="$(tailscale ip -4 2>/dev/null | awk 'NR == 1 { print; exit }')" || true
	[ -n "$ip" ] || {
		printf '  ✗ tailscale not up\n' >&2
		return 1
	}
	printf '  ✓ %s\n' "$ip"
}

run_full_healthcheck() {
	local failed=0

	check_disk || failed=1
	printf '› Service status\n'
	check_services sshd docker tailscaled uncloud hermes-chromium hermes || failed=1
	printf '› Hermes container\n'
	check_hermes || failed=1
	check_backup || failed=1
	check_tailscale || failed=1
	[ "$failed" -eq 0 ]
}

case "$PHASE" in
test | reboot)
	check_rollout
	;;
healthcheck)
	run_full_healthcheck
	;;
esac
