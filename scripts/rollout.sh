#!/usr/bin/env bash
#
# The rollout boundary for kodo. Local policy, SSH transport, and the host
# health adapter meet here so deploy and healthcheck cannot grow separate
# safety sequences.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_HOST="kodo.witek.sh"
DEFAULT_REMOTE_REPO_DIR="/etc/homelab"
DEFAULT_REMOTE_CURRENT_SYSTEM="/run/current-system"
DEFAULT_REMOTE_SYSTEM_PROFILE="/nix/var/nix/profiles/system"
HOST_ROLLOUT_CHECK="${HOMELAB_HOST_ROLLOUT_CHECK:-/run/current-system/sw/bin/homelab-rollout-check}"
REMOTE_REPO_DIR="${HOMELAB_REMOTE_REPO_DIR:-$DEFAULT_REMOTE_REPO_DIR}"
REMOTE_CURRENT_SYSTEM="${HOMELAB_REMOTE_CURRENT_SYSTEM:-$DEFAULT_REMOTE_CURRENT_SYSTEM}"
REMOTE_SYSTEM_PROFILE="${HOMELAB_REMOTE_SYSTEM_PROFILE:-$DEFAULT_REMOTE_SYSTEM_PROFILE}"
BUILD_OUTPUT_FILE=""

log() { printf '› %s\n' "$*"; }
ok() { printf '✓ %s\n' "$*"; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

cleanup_local_artifacts() {
	if [ -n "$BUILD_OUTPUT_FILE" ]; then
		rm -f -- "$BUILD_OUTPUT_FILE"
	fi
}

trap cleanup_local_artifacts EXIT

usage() {
	cat >&2 <<'USAGE'
usage:
  rollout.sh deploy [host] [--approve-closure-diff <sha>]
  rollout.sh healthcheck [host]

Environment:
  HOMELAB_HOST       SSH host (default: kodo.witek.sh)
  HOMELAB_REPO_DIR   local checkout (default: repository root)
  HOMELAB_REMOTE_SYSTEM_PROFILE  system profile (default: /nix/var/nix/profiles/system)
  HOMELAB_SSH_KEY    SSH identity (default: ~/.ssh/id_ed25519)
USAGE
}

validate_sha() {
	local sha="$1"

	case "$sha" in
	'') die "revision cannot be empty" ;;
	*[!0-9a-fA-F]*) die "revision is not a hexadecimal Git object ID: $sha" ;;
	esac
}

validate_host() {
	local host="$1"

	[ -n "$host" ] || die "host cannot be empty"
	[ "${#host}" -le 253 ] || die "host is too long: $host"
	[[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]] ||
		die "host is not a valid DNS hostname: $host"
}

parse_host() {
	[ "$#" -le 1 ] || {
		usage
		exit 2
	}

	HOST="${1:-${HOMELAB_HOST:-$DEFAULT_HOST}}"
	validate_host "$HOST"
	REMOTE="admin@${HOST}"
}

configure_ssh() {
	SSH_KEY="${HOMELAB_SSH_KEY-${HOME}/.ssh/id_ed25519}"
	[ -n "$SSH_KEY" ] || die "HOMELAB_SSH_KEY cannot be empty"
	[ -r "$SSH_KEY" ] || die "SSH key is not readable: $SSH_KEY"
	command -v ssh >/dev/null 2>&1 || die "ssh is required"

	SSH=(ssh -T -i "$SSH_KEY" -o IdentitiesOnly=yes -o ControlPath=none -o ConnectTimeout=10)
}

validate_remote_paths() {
	case "$REMOTE_REPO_DIR" in
	/*) ;;
	*) die "remote repository path must be absolute: $REMOTE_REPO_DIR" ;;
	esac
	case "$REMOTE_CURRENT_SYSTEM" in
	/*) ;;
	*) die "remote current-system path must be absolute: $REMOTE_CURRENT_SYSTEM" ;;
	esac
	case "$REMOTE_SYSTEM_PROFILE" in
	/*) ;;
	*) die "remote system profile path must be absolute: $REMOTE_SYSTEM_PROFILE" ;;
	esac
}

run_remote_script() {
	"${SSH[@]}" "$REMOTE" bash --noprofile --norc -s -- "$@"
}

run_remote_check() {
	local phase="$1"

	"${SSH[@]}" "$REMOTE" sudo "$HOST_ROLLOUT_CHECK" --phase "$phase"
}

prepare_local_checkout() {
	REPO_DIR="${HOMELAB_REPO_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
	[ -d "$REPO_DIR" ] || die "repository directory does not exist: $REPO_DIR"
	cd "$REPO_DIR"

	command -v git >/dev/null 2>&1 || die "git is required"
	git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a Git checkout: $REPO_DIR"
	[ "$(git branch --show-current)" = main ] || die "deploys must run from main"
	[ -z "$(git status --porcelain)" ] || die "the local worktree is not clean"
}

fast_forward_remote_checkout() {
	local expected_sha="$1"

	log "Fast-forwarding $REMOTE_REPO_DIR to origin/main"
	run_remote_script "$expected_sha" "$REMOTE_REPO_DIR" <<'REMOTE'
set -euo pipefail

expected_sha="$1"
remote_repo_dir="$2"
case "$expected_sha" in
  ''|*[!0-9a-fA-F]*) echo "error: invalid expected deployment revision" >&2; exit 1 ;;
esac

sudo test -d "$remote_repo_dir/.git" || {
  printf 'error: %s is not a Git checkout; run the documented one-time migration\n' "$remote_repo_dir" >&2
  exit 1
}
test -z "$(sudo git -C "$remote_repo_dir" status --porcelain)" || {
  echo "error: remote checkout has local changes" >&2
  sudo git -C "$remote_repo_dir" status --short >&2
  exit 1
}
sudo git -C "$remote_repo_dir" fetch origin main --prune
origin_sha="$(sudo git -C "$remote_repo_dir" rev-parse --verify 'origin/main^{commit}')"
[ "$origin_sha" = "$expected_sha" ] || {
  printf 'error: remote origin/main is %s, expected frozen SHA %s\n' "$origin_sha" "$expected_sha" >&2
  exit 1
}
sudo git -C "$remote_repo_dir" checkout main
sudo git -C "$remote_repo_dir" merge --ff-only "$expected_sha"
assert_frozen_checkout() {
  [ "$(sudo git -C "$remote_repo_dir" rev-parse --verify HEAD)" = "$expected_sha" ] || {
    echo "error: remote checkout is not the frozen deployment revision" >&2
    exit 1
  }
  [ -z "$(sudo git -C "$remote_repo_dir" status --porcelain)" ] || {
    echo "error: remote checkout became dirty after fast-forward" >&2
    sudo git -C "$remote_repo_dir" status --short >&2
    exit 1
  }
}

assert_frozen_checkout
REMOTE
}

build_and_compare_closure() {
	local expected_sha="$1" approval_sha="$2" build_output line build_status

	log "Building and comparing the new closure"
	BUILD_OUTPUT_FILE="$(mktemp)"
	if build_closure_remotely "$expected_sha" "$approval_sha" >"$BUILD_OUTPUT_FILE"; then
		build_status=0
	else
		build_status=$?
	fi

	# A deliberate approval refusal still produces the review receipt. Print it
	# before returning the refusal status so set -e cannot hide the diff.
	cat "$BUILD_OUTPUT_FILE"
	build_output="$(<"$BUILD_OUTPUT_FILE")"
	[ "$build_status" -eq 0 ] || return "$build_status"

	CANDIDATE_CLOSURE=""
	while IFS= read -r line; do
		case "$line" in
		candidate_closure=*) CANDIDATE_CLOSURE="${line#candidate_closure=}" ;;
		esac
	done <<<"$build_output"
	[ -n "$CANDIDATE_CLOSURE" ] || die "approved build did not return a candidate closure"
	case "$CANDIDATE_CLOSURE" in
	/*) ;;
	*) die "candidate closure is not an absolute path: $CANDIDATE_CLOSURE" ;;
	esac
}

build_closure_remotely() {
	local expected_sha="$1" approval_sha="$2"

	run_remote_script "$expected_sha" "$REMOTE_REPO_DIR" "$REMOTE_CURRENT_SYSTEM" "$approval_sha" <<'REMOTE'
set -euo pipefail

expected_sha="$1"
remote_repo_dir="$2"
remote_current_system="$3"
approval_sha="${4:-}"
case "$expected_sha" in
  ''|*[!0-9a-fA-F]*) echo "error: invalid expected deployment revision" >&2; exit 1 ;;
esac
[ -z "$approval_sha" ] || case "$approval_sha" in
  *[!0-9a-fA-F]*) echo "error: invalid closure approval revision" >&2; exit 1 ;;
esac
[ -z "$approval_sha" ] || [ "$approval_sha" = "$expected_sha" ] || {
  echo "error: closure approval does not match the frozen deployment revision" >&2
  exit 1
}

assert_frozen_checkout() {
  [ "$(sudo git -C "$remote_repo_dir" rev-parse --verify HEAD)" = "$expected_sha" ] || {
    echo "error: checkout changed after the frozen revision was verified" >&2
    exit 1
  }
  [ -z "$(sudo git -C "$remote_repo_dir" status --porcelain)" ] || {
    echo "error: remote checkout is dirty before the immutable build" >&2
    sudo git -C "$remote_repo_dir" status --short >&2
    exit 1
  }
}

assert_frozen_checkout

tmp_root="$(mktemp -d)"
build_dir="$tmp_root/source"
worktree_added=false
tmpdir=""

cleanup_build_worktree() {
  status=$?
  trap - EXIT
  if [ "$worktree_added" = true ]; then
    if ! sudo git -C "$remote_repo_dir" worktree remove --force "$build_dir"; then
      printf 'error: could not remove temporary build worktree: %s\n' "$build_dir" >&2
      status=1
    fi
  fi
  if [ -n "$tmpdir" ] && [ -d "$tmpdir" ] && ! rm -r -- "$tmpdir"; then
    printf 'error: could not remove temporary comparison directory: %s\n' "$tmpdir" >&2
    status=1
  fi
  if [ -d "$tmp_root" ] && ! rm -r -- "$tmp_root"; then
    printf 'error: could not remove temporary build directory: %s\n' "$tmp_root" >&2
    status=1
  fi
  exit "$status"
}
trap cleanup_build_worktree EXIT

sudo git -C "$remote_repo_dir" worktree add --detach "$build_dir" "$expected_sha"
worktree_added=true
[ "$(sudo git -C "$build_dir" rev-parse --verify HEAD)" = "$expected_sha" ] || {
  echo "error: temporary build worktree is not the frozen deployment revision" >&2
  exit 1
}
[ -z "$(sudo git -C "$build_dir" status --porcelain)" ] || {
  echo "error: temporary build worktree is dirty" >&2
  sudo git -C "$build_dir" status --short >&2
  exit 1
}

cd "$build_dir"
sudo nixos-rebuild build --flake .#kodo

# Capture this before any comparison or approval handling. Every later phase
# receives this canonical store path, never the temporary worktree or `result`
# symlink.
candidate_closure="$(readlink -f result)"
[ -d "$candidate_closure" ] || {
  printf 'error: build result is not a closure directory: %s\n' "$candidate_closure" >&2
  exit 1
}
[ -x "$candidate_closure/bin/switch-to-configuration" ] || {
  printf 'error: candidate closure has no supported activation interface: %s\n' "$candidate_closure" >&2
  exit 1
}

# Emit the identity before the approval gate. A deliberate refusal must still
# leave a complete, auditable diff receipt for the operator.
printf 'candidate_closure=%s\n' "$candidate_closure"

compare_closure() {
  local label="$1" current="$2" candidate="$3" result

  [ -e "$current" ] || { printf 'error: missing current %s: %s\n' "$label" "$current" >&2; return 2; }
  [ -e "$candidate" ] || { printf 'error: missing candidate %s: %s\n' "$label" "$candidate" >&2; return 2; }
  printf '%s:\n' "$label"
  if diff -u "$current" "$candidate"; then
    return 0
  else
    result=$?
  fi
  if [ "$result" -ne 1 ]; then
    printf 'error: could not compare %s (diff exited %s)\n' "$label" "$result" >&2
    return "$result"
  fi
  printf 'warning: %s differ; review every line before continuing\n' "$label" >&2
  return 1
}

tmpdir="$(mktemp -d)"

make_listing() {
  local label="$1" path="$2" output="$3"

  [ -d "$path" ] || {
    printf 'error: missing %s directory: %s\n' "$label" "$path" >&2
    return 2
  }
  if ! find "$path" -maxdepth 1 -printf '%f\n' | sort >"$output"; then
    printf 'error: could not list %s: %s\n' "$label" "$path" >&2
    return 2
  fi
}

make_listing "current systemd units" "$remote_current_system/etc/systemd/system" "$tmpdir/current-units"
make_listing "candidate systemd units" "$candidate_closure/etc/systemd/system" "$tmpdir/candidate-units"
make_listing "current multi-user wants" "$remote_current_system/etc/systemd/system/multi-user.target.wants" "$tmpdir/current-wants"
make_listing "candidate multi-user wants" "$candidate_closure/etc/systemd/system/multi-user.target.wants" "$tmpdir/candidate-wants"

closure_diff=0
compare_closure "systemd units" "$tmpdir/current-units" "$tmpdir/candidate-units" || {
  result=$?
  [ "$result" -eq 1 ] && closure_diff=1 || exit "$result"
}
compare_closure "multi-user wants" "$tmpdir/current-wants" "$tmpdir/candidate-wants" || {
  result=$?
  [ "$result" -eq 1 ] && closure_diff=1 || exit "$result"
}
compare_closure "kernel parameters" "$remote_current_system/kernel-params" "$candidate_closure/kernel-params" || {
  result=$?
  [ "$result" -eq 1 ] && closure_diff=1 || exit "$result"
}

if [ "$closure_diff" -ne 0 ]; then
  [ "$approval_sha" = "$expected_sha" ] || {
    printf 'error: closure differences block rollout; rerun with --approve-closure-diff %s after review\n' "$expected_sha" >&2
    exit 1
  }
  printf 'closure differences acknowledged for frozen revision %s\n' "$expected_sha"
fi
REMOTE
}

activate_candidate() {
	local phase="$1" label="$2"

	[ -n "$label" ] && log "$label"
	run_remote_script "$EXPECTED_SHA" "$CANDIDATE_CLOSURE" "$REMOTE_REPO_DIR" "$REMOTE_CURRENT_SYSTEM" "$REMOTE_SYSTEM_PROFILE" "$phase" <<'REMOTE'
set -euo pipefail

expected_sha="$1"
candidate_closure="$2"
remote_repo_dir="$3"
remote_current_system="$4"
remote_system_profile="$5"
phase="$6"
[ "$(sudo git -C "$remote_repo_dir" rev-parse --verify HEAD)" = "$expected_sha" ] || {
  echo "error: checkout changed before activation" >&2
  exit 1
}
[ -z "$(sudo git -C "$remote_repo_dir" status --porcelain)" ] || {
  echo "error: checkout is dirty before activation" >&2
  sudo git -C "$remote_repo_dir" status --short >&2
  exit 1
}
[ -x "$candidate_closure/bin/switch-to-configuration" ] || {
  echo "error: candidate closure has no supported activation interface" >&2
  exit 1
}

if [ "$phase" = boot ]; then
  printf 'registering candidate in the system profile\n'
  sudo nix-env -p "$remote_system_profile" --set "$candidate_closure"
  boot_profile="$(readlink -f "$remote_system_profile")"
  [ "$boot_profile" = "$candidate_closure" ] || {
    printf 'error: system profile is %s before boot, expected %s\n' "$boot_profile" "$candidate_closure" >&2
    exit 1
  }
fi

sudo "$candidate_closure/bin/switch-to-configuration" "$phase"
current_system="$(readlink -f "$remote_current_system")"
[ "$current_system" = "$candidate_closure" ] || {
  printf 'error: %s activation selected %s, expected %s\n' "$phase" "$current_system" "$candidate_closure" >&2
  exit 1
}
if [ "$phase" = boot ]; then
  boot_profile="$(readlink -f "$remote_system_profile")"
  [ "$boot_profile" = "$candidate_closure" ] || {
    printf 'error: %s activation left system profile at %s, expected %s\n' "$phase" "$boot_profile" "$candidate_closure" >&2
    exit 1
  }
fi
REMOTE
}

wait_for_ssh_disconnect() {
	log "Waiting for the old SSH endpoint to stop"
	local went_down=false
	for _ in $(seq 1 30); do
		if ! "${SSH[@]}" "$REMOTE" true 2>/dev/null; then
			went_down=true
			break
		fi
		sleep 2
	done
	[ "$went_down" = true ] || die "host never became unreachable; reboot was not proven"
}

wait_for_ssh_available() {
	log "Waiting for a fresh SSH connection after reboot"
	for _ in $(seq 1 60); do
		if "${SSH[@]}" "$REMOTE" true 2>/dev/null; then
			break
		fi
		sleep 5
	done
	"${SSH[@]}" "$REMOTE" true 2>/dev/null || die "host did not return after reboot"
}

verify_reboot_identity() {
	local before_boot_id="$1" after_boot_id

	after_boot_id="$(
		run_remote_script "$EXPECTED_SHA" "$CANDIDATE_CLOSURE" "$REMOTE_REPO_DIR" "$REMOTE_CURRENT_SYSTEM" "$REMOTE_SYSTEM_PROFILE" <<'REMOTE'
set -euo pipefail

expected_sha="$1"
candidate_closure="$2"
remote_repo_dir="$3"
remote_current_system="$4"
remote_system_profile="$5"
[ "$(sudo git -C "$remote_repo_dir" rev-parse --verify HEAD)" = "$expected_sha" ] || {
  echo "error: checkout changed after reboot" >&2
  exit 1
}
[ -z "$(sudo git -C "$remote_repo_dir" status --porcelain)" ] || {
  echo "error: checkout is dirty after reboot" >&2
  sudo git -C "$remote_repo_dir" status --short >&2
  exit 1
}
current_system="$(readlink -f "$remote_current_system")"
[ "$current_system" = "$candidate_closure" ] || {
  printf 'error: reboot selected %s, expected %s\n' "$current_system" "$candidate_closure" >&2
  exit 1
}
system_profile="$(readlink -f "$remote_system_profile")"
[ "$system_profile" = "$candidate_closure" ] || {
  printf 'error: reboot system profile is %s, expected %s\n' "$system_profile" "$candidate_closure" >&2
  exit 1
}
cat /proc/sys/kernel/random/boot_id
REMOTE
	)"
	[ -n "$after_boot_id" ] || die "host returned without a boot ID"
	[ "$after_boot_id" != "$before_boot_id" ] || die "boot ID did not change; reboot was not proven"
	ok "reboot changed boot ID"
}

wait_for_rollout_health() {
	log "Waiting for post-reboot rollout health"
	for _ in $(seq 1 60); do
		if run_remote_check reboot >/dev/null 2>&1; then
			run_remote_check reboot
			return
		fi
		sleep 5
	done
	run_remote_check reboot
}

deploy() {
	parse_deploy_args "$@"
	configure_ssh
	prepare_local_checkout
	validate_remote_paths

	log "Checking that local main is published"
	git fetch origin main
	EXPECTED_SHA="$(git rev-parse --verify 'origin/main^{commit}')"
	validate_sha "$EXPECTED_SHA"
	[ "$(git rev-parse --verify HEAD)" = "$EXPECTED_SHA" ] ||
		die "local main and origin/main differ; publish or reconcile before deploying"
	[ -z "$APPROVED_CLOSURE_SHA" ] ||
		[ "$APPROVED_CLOSURE_SHA" = "$EXPECTED_SHA" ] ||
		die "closure approval is stale or does not match frozen revision $EXPECTED_SHA"

	fast_forward_remote_checkout "$EXPECTED_SHA"
	build_and_compare_closure "$EXPECTED_SHA" "$APPROVED_CLOSURE_SHA"

	activate_candidate test "Activating the approved candidate without changing the boot default"

	log "Verifying SSH from a new connection"
	run_remote_check test

	activate_candidate boot "Setting the tested candidate as the boot default"

	log "Capturing the pre-reboot boot ID"
	BEFORE_BOOT_ID="$(
		run_remote_script "$EXPECTED_SHA" "$REMOTE_REPO_DIR" <<'REMOTE'
set -euo pipefail

expected_sha="$1"
remote_repo_dir="$2"
[ "$(sudo git -C "$remote_repo_dir" rev-parse --verify HEAD)" = "$expected_sha" ] || {
  echo "error: checkout changed before reboot" >&2
  exit 1
}
[ -z "$(sudo git -C "$remote_repo_dir" status --porcelain)" ] || {
  echo "error: checkout is dirty before reboot" >&2
  sudo git -C "$remote_repo_dir" status --short >&2
  exit 1
}
cat /proc/sys/kernel/random/boot_id
REMOTE
	)"
	[ -n "$BEFORE_BOOT_ID" ] || die "host returned an empty pre-reboot boot ID"

	log "Rebooting $HOST"
	reboot_receipt=""
	reboot_status=0
	if reboot_receipt="$(
		"${SSH[@]}" "$REMOTE" bash --noprofile --norc -s -- "$EXPECTED_SHA" "$REMOTE_REPO_DIR" <<'REMOTE'
set -euo pipefail

expected_sha="$1"
remote_repo_dir="$2"
[ "$(sudo git -C "$remote_repo_dir" rev-parse --verify HEAD)" = "$expected_sha" ] || {
  echo "error: checkout changed before reboot scheduling" >&2
  exit 1
}
[ -z "$(sudo git -C "$remote_repo_dir" status --porcelain)" ] || {
  echo "error: checkout is dirty before reboot scheduling" >&2
  sudo git -C "$remote_repo_dir" status --short >&2
  exit 1
}
if sudo systemctl reboot --no-block; then
  printf 'reboot-accepted\n'
else
  status=$?
  printf 'error: reboot scheduling command was rejected\n' >&2
  exit "$status"
fi
REMOTE
	)"; then
		reboot_status=0
	else
		reboot_status=$?
	fi
	[ "$reboot_receipt" = reboot-accepted ] ||
		die "reboot scheduling was not acknowledged (ssh exit $reboot_status)"
	[ "$reboot_status" -eq 0 ] || [ "$reboot_status" -eq 255 ] ||
		die "reboot scheduling failed with ssh exit $reboot_status"
	wait_for_ssh_disconnect
	wait_for_ssh_available
	verify_reboot_identity "$BEFORE_BOOT_ID"
	wait_for_rollout_health

	log "Verifying the deployed checkout and generation"
	run_remote_script "$EXPECTED_SHA" "$CANDIDATE_CLOSURE" "$REMOTE_REPO_DIR" "$REMOTE_CURRENT_SYSTEM" "$REMOTE_SYSTEM_PROFILE" <<'REMOTE'
set -euo pipefail
expected_sha="$1"
candidate_closure="$2"
remote_repo_dir="$3"
remote_current_system="$4"
remote_system_profile="$5"
[ "$(sudo git -C "$remote_repo_dir" rev-parse --verify HEAD)" = "$expected_sha" ] || {
  printf 'error: final checkout is not the frozen deployment revision\n' >&2
  exit 1
}
[ -z "$(sudo git -C "$remote_repo_dir" status --porcelain)" ] || {
  printf 'error: final checkout is dirty\n' >&2
  sudo git -C "$remote_repo_dir" status --short >&2
  exit 1
}
current_system="$(readlink -f "$remote_current_system")"
[ "$current_system" = "$candidate_closure" ] || {
	printf 'error: final current-system is %s, expected %s\n' "$current_system" "$candidate_closure" >&2
	exit 1
}
system_profile="$(readlink -f "$remote_system_profile")"
[ "$system_profile" = "$candidate_closure" ] || {
	printf 'error: final system profile is %s, expected %s\n' "$system_profile" "$candidate_closure" >&2
	exit 1
}
printf "generation=%s\n" "$current_system"
REMOTE

	ok "deploy complete on $HOST"
}

parse_deploy_args() {
	local host_arg=""

	APPROVED_CLOSURE_SHA=""
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--approve-closure-diff)
			[ "$#" -ge 2 ] || {
				usage
				exit 2
			}
			APPROVED_CLOSURE_SHA="$2"
			shift 2
			;;
		-*)
			usage
			exit 2
			;;
		*)
			[ -z "$host_arg" ] || {
				usage
				exit 2
			}
			host_arg="$1"
			shift
			;;
		esac
	done

	if [ -n "$host_arg" ]; then
		parse_host "$host_arg"
	else
		parse_host
	fi
}

healthcheck() {
	parse_host "$@"
	configure_ssh
	log "Running host health checks on $HOST"
	run_remote_check healthcheck
}

[ "$#" -gt 0 ] || {
	usage
	exit 2
}

COMMAND="$1"
shift
case "$COMMAND" in
deploy) deploy "$@" ;;
healthcheck) healthcheck "$@" ;;
*)
	usage
	exit 2
	;;
esac
