#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROLLOUT="$SCRIPT_DIR/rollout.sh"
HOST_CHECK="$SCRIPT_DIR/rollout-host-check.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -r -- "$TEST_ROOT"' EXIT

EXPECTED_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
STALE_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
BIN_DIR="$TEST_ROOT/bin"
REPO_DIR="$TEST_ROOT/repo"
REMOTE_REPO_DIR="$TEST_ROOT/remote-repo"
REMOTE_CURRENT_SYSTEM="$TEST_ROOT/current-system"
REMOTE_SYSTEM_PROFILE="$TEST_ROOT/system-profile"
CANDIDATE_CLOSURE="$TEST_ROOT/nixos-system-kodo-candidate"
WRONG_CLOSURE="$TEST_ROOT/nixos-system-kodo-wrong"
INITIAL_CLOSURE="$TEST_ROOT/nixos-system-kodo-initial"
KEY_FILE="$TEST_ROOT/key"
OUTPUT_FILE="$TEST_ROOT/output"
SSH_STATE_FILE="$TEST_ROOT/ssh-state"
REBOOT_MARKER="$TEST_ROOT/reboot-scheduled"
ACTIVATION_LOG="$TEST_ROOT/activation-log"
HEALTH_LOG="$TEST_ROOT/health-log"
HOST_COMMAND_LOG="$TEST_ROOT/host-command-log"
BUILD_SOURCE_LOG="$TEST_ROOT/build-source"
WORKTREE_ADD_LOG="$TEST_ROOT/worktree-add"
WORKTREE_REMOVE_LOG="$TEST_ROOT/worktree-remove"

mkdir -p "$BIN_DIR" "$REPO_DIR" "$REMOTE_REPO_DIR/.git"
printf 'test key\n' >"$KEY_FILE"

make_closure() {
	local closure="$1"
	mkdir -p \
		"$closure/bin" \
		"$closure/etc/systemd/system/multi-user.target.wants"
	printf 'console=ttyS0,115200\n' >"$closure/kernel-params"
	: >"$closure/etc/systemd/system/sshd.service"
	: >"$closure/etc/systemd/system/multi-user.target.wants/sshd.service"
	cat >"$closure/bin/switch-to-configuration" <<'SWITCH'
#!/usr/bin/env bash
set -euo pipefail

phase="${1:?activation phase is required}"
case "$phase" in
test | boot) ;;
*) printf 'unexpected activation phase: %s\n' "$phase" >&2; exit 2 ;;
esac

closure="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
case "$phase" in
test)
	if [ "${MOCK_SCENARIO:-}" = wrong-current-after-test ]; then
		closure="$MOCK_WRONG_CLOSURE"
	fi
	rm -f "$MOCK_REMOTE_CURRENT_SYSTEM"
	ln -s "$closure" "$MOCK_REMOTE_CURRENT_SYSTEM"
	;;
boot)
	if [ "${MOCK_SCENARIO:-}" = wrong-current-after-boot ]; then
		rm -f "$MOCK_REMOTE_CURRENT_SYSTEM"
		ln -s "$MOCK_WRONG_CLOSURE" "$MOCK_REMOTE_CURRENT_SYSTEM"
	fi
	;;
esac
printf '%s %s\n' "$phase" "$closure" >>"$MOCK_ACTIVATION_LOG"
SWITCH
	chmod +x "$closure/bin/switch-to-configuration"
}

make_closure "$CANDIDATE_CLOSURE"
make_closure "$WRONG_CLOSURE"
make_closure "$INITIAL_CLOSURE"
CANDIDATE_CLOSURE="$(cd -- "$CANDIDATE_CLOSURE" && pwd -P)"
WRONG_CLOSURE="$(cd -- "$WRONG_CLOSURE" && pwd -P)"
INITIAL_CLOSURE="$(cd -- "$INITIAL_CLOSURE" && pwd -P)"

cat >"$BIN_DIR/git" <<'MOCK_GIT'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
*"rev-parse --is-inside-work-tree"*) printf 'true\n' ;;
*"branch --show-current"*) printf 'main\n' ;;
*"status --porcelain"*)
	if [ -e "${MOCK_REMOTE_REPO:-}/dirty-file" ]; then
		printf ' M tracked-file\n'
	fi
	;;
*"status --short"*) ;;
*"fetch origin main"*) ;;
*"rev-parse --verify origin/main^{commit}"*)
	if [ "${MOCK_SCENARIO:-}" = revision-mismatch ] && [[ "$*" = *"$MOCK_REMOTE_REPO"* ]]; then
		printf '%s\n' "$MOCK_STALE_SHA"
	else
		printf '%s\n' "$MOCK_EXPECTED_SHA"
	fi
	;;
*"rev-parse --verify HEAD"*) printf '%s\n' "$MOCK_EXPECTED_SHA" ;;
*"checkout main"*) ;;
*"merge --ff-only"*)
	if [ "${MOCK_SCENARIO:-}" = dirty-before-build ]; then
		touch "$MOCK_REMOTE_REPO/dirty-file"
	fi
	;;
*"worktree add --detach"*)
	printf '%s %s\n' "${6:?temporary worktree path is required}" "${7:?frozen revision is required}" >"$MOCK_WORKTREE_ADD_LOG"
	mkdir -p "${6:?temporary worktree path is required}"
	;;
*"worktree remove --force"*)
	printf '%s\n' "${6:?temporary worktree path is required}" >"$MOCK_WORKTREE_REMOVE_LOG"
	rm -r -- "${6:?temporary worktree path is required}"
	;;
*) printf 'unexpected mock git invocation: %s\n' "$*" >&2; exit 1 ;;
esac
MOCK_GIT

cat >"$BIN_DIR/diff" <<'MOCK_DIFF'
#!/usr/bin/env bash
set -euo pipefail

case "${MOCK_DIFF_STATUS:?MOCK_DIFF_STATUS is required}" in
0) exit 0 ;;
1) printf '%s\n' 'mock closure difference' ; exit 1 ;;
*) printf '%s\n' 'mock diff failure' >&2; exit 2 ;;
esac
MOCK_DIFF

cat >"$BIN_DIR/find" <<'MOCK_FIND'
#!/usr/bin/env bash
set -euo pipefail

path="${1:?find path is required}"
printf '%s\n' "${path##*/}"
for entry in "$path"/*; do
	[ -e "$entry" ] || continue
	printf '%s\n' "${entry##*/}"
done
MOCK_FIND

cat >"$BIN_DIR/readlink" <<'MOCK_READLINK'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = -f ]; then
	cd -- "${2:?path is required}" && pwd -P
	exit 0
fi
exec /usr/bin/readlink "$@"
MOCK_READLINK

cat >"$BIN_DIR/nixos-rebuild" <<'MOCK_NIXOS_REBUILD'
#!/usr/bin/env bash
set -euo pipefail

[ "${1:-}" = build ] || {
	printf 'unexpected nixos-rebuild invocation: %s\n' "$*" >&2
	exit 1
}
pwd >"$MOCK_BUILD_SOURCE_LOG"
rm -f result
ln -s "$MOCK_CANDIDATE_CLOSURE" result
MOCK_NIXOS_REBUILD

cat >"$BIN_DIR/systemctl" <<'MOCK_SYSTEMCTL'
#!/usr/bin/env bash
set -euo pipefail

printf 'systemctl %s\n' "$*" >>"$MOCK_HOST_COMMAND_LOG"
case "${1:-}" in
is-active)
	if [ "${2:-}" = --quiet ]; then
		service="${3:?service is required}"
	else
		service="${2:?service is required}"
	fi
	if [ "${MOCK_HOST_SCENARIO:-}" = service-failure ] && [ "$service" = docker ]; then
		exit 1
	fi
	if [ "${MOCK_HOST_SCENARIO:-}" = all-health-failures ]; then
		exit 1
	fi
	;;
reboot)
	if [ "${MOCK_SCENARIO:-}" = rejected-reboot ]; then
		exit 1
	fi
	touch "$MOCK_REBOOT_MARKER"
	boot_profile="$(readlink -f "$MOCK_SYSTEM_PROFILE")"
	rm -f "$MOCK_REMOTE_CURRENT_SYSTEM"
	ln -s "$boot_profile" "$MOCK_REMOTE_CURRENT_SYSTEM"
	if [ "${MOCK_SCENARIO:-}" = wrong-post-reboot-path ]; then
		rm -f "$MOCK_REMOTE_CURRENT_SYSTEM"
		ln -s "$MOCK_WRONG_CLOSURE" "$MOCK_REMOTE_CURRENT_SYSTEM"
	fi
	;;
*)
	printf 'unexpected systemctl invocation: %s\n' "$*" >&2
	exit 1
	;;
esac
MOCK_SYSTEMCTL

cat >"$BIN_DIR/docker" <<'MOCK_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

printf 'docker %s\n' "$*" >>"$MOCK_HOST_COMMAND_LOG"
case "${1:-}" in
inspect)
	if [ "${MOCK_HOST_SCENARIO:-}" = all-health-failures ]; then
		printf 'unhealthy\n'
	else
		printf 'healthy\n'
	fi
	;;
exec)
	case "${6:-}" in
	stt.provider)
		if [ "${MOCK_HOST_SCENARIO:-}" = hermes-config-failure ] || [ "${MOCK_HOST_SCENARIO:-}" = all-health-failures ]; then
			printf 'cloud\n'
		else
			printf 'local\n'
		fi
		;;
	stt.language)
		if [ "${MOCK_HOST_SCENARIO:-}" = hermes-config-failure ] || [ "${MOCK_HOST_SCENARIO:-}" = all-health-failures ]; then
			printf 'en\n'
		else
			printf 'pt\n'
		fi
		;;
	*)
		printf 'unexpected docker exec invocation: %s\n' "$*" >&2
		exit 1
		;;
	esac
	;;
*)
	printf 'unexpected docker invocation: %s\n' "$*" >&2
	exit 1
	;;
esac
MOCK_DOCKER

cat >"$BIN_DIR/kodo-restic" <<'MOCK_RESTIC'
#!/usr/bin/env bash
set -euo pipefail

printf 'kodo-restic %s\n' "$*" >>"$MOCK_HOST_COMMAND_LOG"
if [ "${MOCK_HOST_SCENARIO:-}" = all-health-failures ]; then
	exit 1
fi
printf '[{"time":"2026-09-01T00:00:00Z","hostname":"kodo","paths":["/etc","/var/lib/homelab"]}]\n'
MOCK_RESTIC

cat >"$BIN_DIR/tailscale" <<'MOCK_TAILSCALE'
#!/usr/bin/env bash
set -euo pipefail

printf 'tailscale %s\n' "$*" >>"$MOCK_HOST_COMMAND_LOG"
if [ "${MOCK_HOST_SCENARIO:-}" = all-health-failures ]; then
	exit 1
fi
printf '100.64.0.10\n'
MOCK_TAILSCALE

cat >"$BIN_DIR/df" <<'MOCK_DF'
#!/usr/bin/env bash
set -euo pipefail

printf 'Filesystem  Size  Used Avail Use%% Mounted on\n'
printf '/dev/mock   10G   2G    8G   20%% /\n'
MOCK_DF

cat >"$BIN_DIR/id" <<'MOCK_ID'
#!/usr/bin/env bash
set -euo pipefail

[ "${1:-}" = -u ] || {
	printf 'unexpected id invocation: %s\n' "$*" >&2
	exit 1
}
printf '0\n'
MOCK_ID

cat >"$BIN_DIR/nix-env" <<'MOCK_NIX_ENV'
#!/usr/bin/env bash
set -euo pipefail

[ "${1:-}" = -p ] && [ "${3:-}" = --set ] || {
	printf 'unexpected nix-env invocation: %s\n' "$*" >&2
	exit 1
}
profile="$2"
candidate="$4"
temporary_profile="$profile.mock.$$"
rm -f "$temporary_profile"
ln -s "$candidate" "$temporary_profile"
rm -f "$profile"
mv -f -- "$temporary_profile" "$profile"
MOCK_NIX_ENV

cat >"$BIN_DIR/cat" <<'MOCK_CAT'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = /proc/sys/kernel/random/boot_id ]; then
	if [ -e "$MOCK_REBOOT_MARKER" ] && [ "${MOCK_SCENARIO:-}" != unchanged-boot-id ]; then
		printf 'after-boot\n'
	else
		printf 'before-boot\n'
	fi
	exit 0
fi
exec /bin/cat "$@"
MOCK_CAT

cat >"$BIN_DIR/sudo" <<'MOCK_SUDO'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
"/fake/homelab-rollout-check")
	if [ "${MOCK_HEALTH_MODE:-}" = adapter ]; then
		"$MOCK_HOST_CHECK" "${@:2}"
	else
		printf '%s\n' "${3:?health phase is required}" >>"$MOCK_HEALTH_LOG"
	fi
	;;
*) exec "$@" ;;
esac
MOCK_SUDO

cat >"$BIN_DIR/ssh" <<'MOCK_SSH'
#!/usr/bin/env bash
set -euo pipefail

remote_index=-1
for ((index = 1; index <= $#; index++)); do
	if [[ "${!index}" == *@* ]]; then
		remote_index="$index"
		break
	fi
done
[ "$remote_index" -ge 0 ] || { printf 'mock ssh did not receive a remote host\n' >&2; exit 1; }
command_index=$((remote_index + 1))
command="${!command_index:-}"

if [ "$command" = true ]; then
	count=0
	[ -e "$MOCK_SSH_STATE" ] && count="$(<"$MOCK_SSH_STATE")"
	count=$((count + 1))
	printf '%s\n' "$count" >"$MOCK_SSH_STATE"
	[ "$count" -gt 1 ]
	exit
fi

if [ "$command" = sudo ]; then
	command_args_start=$((command_index + 1))
	"$MOCK_BIN_DIR/sudo" "${@:command_args_start}"
	exit
fi

[ "$command" = bash ] || {
	printf 'unexpected mock ssh command: %s\n' "$command" >&2
	exit 1
}

output_file="$MOCK_TEST_ROOT/ssh-output"
error_file="$MOCK_TEST_ROOT/ssh-error"
command_args_start=$((command_index + 1))
set +e
/bin/bash "${@:command_args_start}" >"$output_file" 2>"$error_file"
status=$?
set -e
/bin/cat "$error_file" >&2
while IFS= read -r line; do
	if [ "${MOCK_SCENARIO:-}" = missing-reboot-receipt ] && [ "$line" = reboot-accepted ]; then
		continue
	fi
	printf '%s\n' "$line"
done <"$output_file"
exit "$status"
MOCK_SSH

chmod +x "$BIN_DIR"/*

assert_contains() {
	local file="$1" expected="$2" contents

	contents="$(<"$file")"
	case "$contents" in
	*"$expected"*) ;;
	*)
		printf 'missing expected text: %s\n' "$expected" >&2
		return 1
		;;
	esac
}

assert_not_contains() {
	local file="$1" unexpected="$2" contents

	contents="$(<"$file")"
	case "$contents" in
	*"$unexpected"*)
		printf 'unexpected text: %s\n' "$unexpected" >&2
		return 1
		;;
	esac
}

assert_worktree_cleaned() {
	local worktree_path worktree_sha removed_path

	[ -s "$WORKTREE_ADD_LOG" ] || {
		printf 'missing worktree-add receipt\n' >&2
		return 1
	}
	read -r worktree_path worktree_sha <"$WORKTREE_ADD_LOG"
	[ "$worktree_sha" = "$EXPECTED_SHA" ] || {
		printf 'worktree was not created at frozen SHA: %s\n' "$worktree_sha" >&2
		return 1
	}
	[ -s "$WORKTREE_REMOVE_LOG" ] || {
		printf 'missing worktree-remove receipt\n' >&2
		return 1
	}
	removed_path="$(<"$WORKTREE_REMOVE_LOG")"
	[ "$removed_path" = "$worktree_path" ] || {
		printf 'removed worktree differs from added worktree\n' >&2
		return 1
	}
	[ ! -e "$worktree_path" ] || {
		printf 'temporary worktree still exists: %s\n' "$worktree_path" >&2
		return 1
	}
}

reset_remote_state() {
	rm -f "$SSH_STATE_FILE" "$REBOOT_MARKER" "$ACTIVATION_LOG" "$HEALTH_LOG"
	rm -f "$BUILD_SOURCE_LOG" "$WORKTREE_ADD_LOG"
	rm -f "$WORKTREE_REMOVE_LOG"
	rm -f "$REMOTE_REPO_DIR/dirty-file"
	rm -f "$REMOTE_CURRENT_SYSTEM"
	ln -s "$INITIAL_CLOSURE" "$REMOTE_CURRENT_SYSTEM"
	rm -f "$REMOTE_SYSTEM_PROFILE"
	ln -s "$INITIAL_CLOSURE" "$REMOTE_SYSTEM_PROFILE"
	: >"$ACTIVATION_LOG"
	: >"$HEALTH_LOG"
}

rollout_command() {
	env \
		PATH="$BIN_DIR:$PATH" \
		MOCK_BIN_DIR="$BIN_DIR" \
		MOCK_TEST_ROOT="$TEST_ROOT" \
		MOCK_EXPECTED_SHA="$EXPECTED_SHA" \
		MOCK_STALE_SHA="$STALE_SHA" \
		MOCK_SSH_STATE="$SSH_STATE_FILE" \
		MOCK_REBOOT_MARKER="$REBOOT_MARKER" \
		MOCK_ACTIVATION_LOG="$ACTIVATION_LOG" \
		MOCK_HEALTH_LOG="$HEALTH_LOG" \
		MOCK_BUILD_SOURCE_LOG="$BUILD_SOURCE_LOG" \
		MOCK_WORKTREE_ADD_LOG="$WORKTREE_ADD_LOG" \
		MOCK_WORKTREE_REMOVE_LOG="$WORKTREE_REMOVE_LOG" \
		MOCK_HOST_COMMAND_LOG="$HOST_COMMAND_LOG" \
		MOCK_HOST_CHECK="$HOST_CHECK" \
		MOCK_REMOTE_REPO="$REMOTE_REPO_DIR" \
		MOCK_REMOTE_CURRENT_SYSTEM="$REMOTE_CURRENT_SYSTEM" \
		MOCK_SYSTEM_PROFILE="$REMOTE_SYSTEM_PROFILE" \
		MOCK_CANDIDATE_CLOSURE="$CANDIDATE_CLOSURE" \
		MOCK_WRONG_CLOSURE="$WRONG_CLOSURE" \
		HOMELAB_REPO_DIR="$REPO_DIR" \
		HOMELAB_REMOTE_REPO_DIR="$REMOTE_REPO_DIR" \
		HOMELAB_REMOTE_CURRENT_SYSTEM="$REMOTE_CURRENT_SYSTEM" \
		HOMELAB_REMOTE_SYSTEM_PROFILE="$REMOTE_SYSTEM_PROFILE" \
		HOMELAB_HOST_ROLLOUT_CHECK=/fake/homelab-rollout-check \
		HOMELAB_RESTIC_COMMAND="$BIN_DIR/kodo-restic" \
		HOMELAB_SSH_KEY="$KEY_FILE" \
		"$@"
}

run_rollout() {
	local scenario="$1" diff_status="$2" approval_sha="${3:-}"

	reset_remote_state
	set +e
	if [ -n "$approval_sha" ]; then
		rollout_command env MOCK_SCENARIO="$scenario" MOCK_DIFF_STATUS="$diff_status" \
			"$ROLLOUT" deploy kodo.witek.sh --approve-closure-diff "$approval_sha" >"$OUTPUT_FILE" 2>&1
	else
		rollout_command env MOCK_SCENARIO="$scenario" MOCK_DIFF_STATUS="$diff_status" \
			"$ROLLOUT" deploy kodo.witek.sh >"$OUTPUT_FILE" 2>&1
	fi
	CASE_STATUS=$?
	set -e
}

run_host_check() {
	local scenario="$1" phase="$2"

	: >"$HOST_COMMAND_LOG"
	set +e
	env \
		PATH="$BIN_DIR:$PATH" \
		MOCK_HOST_COMMAND_LOG="$HOST_COMMAND_LOG" \
		MOCK_HOST_SCENARIO="$scenario" \
		HOMELAB_RESTIC_COMMAND="$BIN_DIR/kodo-restic" \
		"$HOST_CHECK" --phase "$phase" >"$OUTPUT_FILE" 2>&1
	CASE_STATUS=$?
	set -e
}

run_rollout_healthcheck() {
	local scenario="$1"

	: >"$HOST_COMMAND_LOG"
	set +e
	rollout_command env \
		MOCK_HEALTH_MODE=adapter \
		MOCK_HOST_SCENARIO="$scenario" \
		"$ROLLOUT" healthcheck kodo.witek.sh >"$OUTPUT_FILE" 2>&1
	CASE_STATUS=$?
	set -e
}

run_rollout success 0
[ "$CASE_STATUS" -eq 0 ]
assert_contains "$OUTPUT_FILE" "candidate_closure=$CANDIDATE_CLOSURE"
assert_contains "$OUTPUT_FILE" "generation=$CANDIDATE_CLOSURE"
assert_contains "$OUTPUT_FILE" 'reboot changed boot ID'
assert_contains "$ACTIVATION_LOG" "test $CANDIDATE_CLOSURE"
assert_contains "$ACTIVATION_LOG" "boot $CANDIDATE_CLOSURE"
assert_contains "$HEALTH_LOG" test
assert_contains "$HEALTH_LOG" reboot
read -r WORKTREE_PATH WORKTREE_SHA <"$WORKTREE_ADD_LOG"
[ "$(<"$BUILD_SOURCE_LOG")" = "$WORKTREE_PATH" ]
[ "$WORKTREE_SHA" = "$EXPECTED_SHA" ]
[ "$(readlink -f "$REMOTE_SYSTEM_PROFILE")" = "$CANDIDATE_CLOSURE" ]
assert_worktree_cleaned

run_rollout changed-closure 1 "$EXPECTED_SHA"
[ "$CASE_STATUS" -eq 0 ]
assert_contains "$OUTPUT_FILE" 'closure differences acknowledged'

run_rollout missing-closure-approval 1
[ "$CASE_STATUS" -ne 0 ]
assert_contains "$OUTPUT_FILE" 'closure differences block rollout'
assert_contains "$OUTPUT_FILE" 'mock closure difference'
assert_contains "$OUTPUT_FILE" "candidate_closure=$CANDIDATE_CLOSURE"
assert_contains "$OUTPUT_FILE" 'systemd units:'
assert_contains "$OUTPUT_FILE" 'multi-user wants:'
assert_contains "$OUTPUT_FILE" 'kernel parameters:'
[ ! -s "$ACTIVATION_LOG" ]
assert_worktree_cleaned

run_rollout diff-error 2
[ "$CASE_STATUS" -ne 0 ]
assert_contains "$OUTPUT_FILE" 'could not compare systemd units (diff exited 2)'
assert_worktree_cleaned

run_rollout stale-approval 0 "$STALE_SHA"
[ "$CASE_STATUS" -ne 0 ]
assert_contains "$OUTPUT_FILE" 'closure approval is stale'

run_rollout revision-mismatch 0
[ "$CASE_STATUS" -ne 0 ]
assert_contains "$OUTPUT_FILE" 'expected frozen SHA'
[ ! -s "$ACTIVATION_LOG" ]

run_rollout wrong-current-after-test 0
[ "$CASE_STATUS" -ne 0 ]
assert_contains "$OUTPUT_FILE" 'test activation selected'
assert_not_contains "$ACTIVATION_LOG" 'boot '
assert_not_contains "$HEALTH_LOG" test

run_rollout wrong-current-after-boot 0
[ "$CASE_STATUS" -ne 0 ]
assert_contains "$OUTPUT_FILE" 'boot activation selected'
assert_not_contains "$HEALTH_LOG" reboot
[ ! -e "$REBOOT_MARKER" ]

run_rollout missing-reboot-receipt 0
[ "$CASE_STATUS" -ne 0 ]
assert_contains "$OUTPUT_FILE" 'reboot scheduling was not acknowledged'

run_rollout rejected-reboot 0
[ "$CASE_STATUS" -ne 0 ]
assert_contains "$OUTPUT_FILE" 'reboot scheduling was not acknowledged'
assert_contains "$OUTPUT_FILE" 'reboot scheduling command was rejected'

run_rollout unchanged-boot-id 0
[ "$CASE_STATUS" -ne 0 ]
assert_contains "$OUTPUT_FILE" 'boot ID did not change; reboot was not proven'

run_rollout wrong-post-reboot-path 0
[ "$CASE_STATUS" -ne 0 ]
assert_contains "$OUTPUT_FILE" 'reboot selected'
assert_not_contains "$HEALTH_LOG" reboot

run_rollout dirty-before-build 0
[ "$CASE_STATUS" -ne 0 ]
assert_contains "$OUTPUT_FILE" 'remote checkout became dirty after fast-forward'
[ ! -s "$ACTIVATION_LOG" ]

run_host_check healthy test
[ "$CASE_STATUS" -eq 0 ]
assert_contains "$OUTPUT_FILE" '✓ sshd'
assert_contains "$OUTPUT_FILE" '✓ uncloud'
assert_not_contains "$HOST_COMMAND_LOG" 'docker inspect'
assert_not_contains "$HOST_COMMAND_LOG" 'kodo-restic'
assert_not_contains "$HOST_COMMAND_LOG" 'tailscale'

run_host_check healthy reboot
[ "$CASE_STATUS" -eq 0 ]
assert_contains "$OUTPUT_FILE" '✓ healthy'
assert_contains "$OUTPUT_FILE" '✓ STT policy local/pt'
assert_contains "$HOST_COMMAND_LOG" 'docker inspect --format'
assert_contains "$HOST_COMMAND_LOG" 'docker exec hermes hermes config get stt.provider'

run_host_check service-failure reboot
[ "$CASE_STATUS" -ne 0 ]
assert_contains "$OUTPUT_FILE" '✗ docker (down)'
assert_contains "$OUTPUT_FILE" '✓ healthy'
assert_contains "$OUTPUT_FILE" '✓ STT policy local/pt'

run_host_check hermes-config-failure reboot
[ "$CASE_STATUS" -ne 0 ]
assert_contains "$OUTPUT_FILE" '✗ Hermes STT provider is not local'
assert_contains "$OUTPUT_FILE" '✗ Hermes STT language is not pt'

run_rollout_healthcheck healthy
[ "$CASE_STATUS" -eq 0 ]
assert_contains "$OUTPUT_FILE" 'Running host health checks on kodo.witek.sh'
assert_contains "$OUTPUT_FILE" 'Latest restic snapshot'
assert_contains "$OUTPUT_FILE" '✓ 100.64.0.10'
assert_contains "$HOST_COMMAND_LOG" 'systemctl is-active --quiet tailscaled'
assert_contains "$HOST_COMMAND_LOG" 'kodo-restic snapshots --json --no-cache'

run_rollout_healthcheck all-health-failures
[ "$CASE_STATUS" -ne 0 ]
assert_contains "$OUTPUT_FILE" '✗ docker (down)'
assert_contains "$OUTPUT_FILE" '✗ unhealthy'
assert_contains "$OUTPUT_FILE" '✗ backup repository unavailable'
assert_contains "$OUTPUT_FILE" '✗ tailscale not up'
assert_contains "$HOST_COMMAND_LOG" 'docker inspect --format'
assert_contains "$HOST_COMMAND_LOG" 'kodo-restic snapshots --json --no-cache'
assert_contains "$HOST_COMMAND_LOG" 'tailscale ip -4'

printf 'rollout mock checks passed\n'
