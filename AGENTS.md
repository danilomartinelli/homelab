# Homelab agent guide

## Scope

- This repository is a NixOS flake for one `x86_64-linux` host: `kodo`.
- It is commonly managed from macOS; do not assume local commands execute on Linux or on the host.
- Treat `flake.lock` as the production dependency lock. Do not update it casually; dependency updates require the full rollout validation sequence.

## Configuration ownership

- `flake.nix` defines `nixosConfigurations.kodo` and composes the top-level modules.
- `modules/default.nix` imports the required modules. `modules/<name>.nix` owns the corresponding infrastructure concern.
- `hosts/kodo/default.nix` wires the host boot, filesystem, and service stack.
- A definition under `services/<name>/` is not deployed merely by existing: wire its stack in `hosts/kodo/default.nix`.

## Local checks

Run the narrow, repository-supported checks before proposing a rollout:

```bash
bash -n scripts/rollout.sh scripts/rollout-host-check.sh scripts/rollout-mock-test.sh
scripts/rollout-mock-test.sh
```

There is no repository Makefile, Taskfile, pre-commit configuration, CI configuration, or formatter configuration. Do not invent a wrapper command or claim an unconfigured check ran.

## Deployment boundary

Use only the rollout entry point; do not recommend manual activation, ad-hoc remote builds, or shortcut SSH commands:

```bash
scripts/rollout.sh deploy kodo.witek.sh
```

The deploy requires a clean, synced local `main` and a clean remote checkout. It freezes `origin/main`, builds in a detached remote worktree, and blocks activation when the closure differs unless explicitly approved with **only the exact frozen SHA**. Its test phase must be verified through a new SSH connection; the existing activation SSH session is not networking proof. The same captured closure is then boot-activated, followed by reboot, boot-ID/generation/profile verification, and host checks.

For health, use the installed host adapter:

```bash
scripts/rollout.sh healthcheck kodo.witek.sh
```

`/etc/homelab/result` is ignored and non-authoritative; if present, it may be stale. Inspect `/run/current-system` and `/nix/var/nix/profiles/system` when identifying the active generation.

## Infrastructure invariants

- Preserve BIOS/GRUB targeting `/dev/sda` and the serial kernel-console settings.
- `hosts/kodo/hardware-configuration.nix` was transcribed from the provider image; do not regenerate it casually. Preserve label root `/dev/disk/by-label/nixos`, `x-systemd.growfs`, and the required initrd modules.
- Cloud-init owns provider networking. Keep `useDHCP=false`; do not replace it with static addressing, re-enable DHCP, or remove cloud-init.
- Compose units depend on Docker and `network-online`; preserve a stable Compose `projectName`.
- Hermes is ordered after Chromium, but Chromium readiness/health is not a Hermes dependency. Hermes uses host-loopback CDP at `127.0.0.1:9223`.
- Do not set `users.mutableUsers = false` without declarative password hashes: it rewrites `/etc/shadow`, and rollback does not repair it. Preserve key-only root SSH/recovery, separately from networking changes.
- Keep the webhook contract aligned across Compose, Caddy, and ingress: listener `10.210.0.1:8090`, path `/whatsapp/webhook`, and TCP port `8090` in the firewall.
- Host rollout does not deploy Uncloud Caddy. Deploy that separately, only when required:

```bash
uc caddy deploy -c loopdodia --image caddy:2.10.2 --caddyfile services/uncloud/Caddyfile
```

- Enabling Tailscale does not join the host. The one-time join operation is `sudo tailscale up --ssh`.
- Backups cover `/var/lib/homelab` and `/etc`; missing paths may be skipped. Verify with `sudo kodo-backup-verify` and `sudo kodo-restic check` (root is required).
- Secrets are SOPS-managed. Never commit plaintext secrets, decrypted dotenv files, or secret-bearing command output.
- `scripts/bootstrap.sh` is stale and unsupported: do not run or recommend it. It targets nonexistent `.#homelab`, bypasses guarded rollout, and references obsolete user setup.

All production mutations require explicit user authorization, including but not limited to deployment/reboot, Caddy deployment, `tailscale up`, secret mutation, and commit/push operations, regardless of whether an example command appears above.

## Test interpretation

- `ConditionPathExists` proves only that a path exists; it does not prove valid secret content.
- Hermes may clean-exit and restart in a loop when channel configuration is missing. Treat that as a configuration/test signal, not automatic service success.
- A passing test activation over the existing SSH connection does not prove provider networking; require the rollout's new-connection verification.

Keep changes scoped to the relevant owner and preserve unrelated working-tree changes. Do not commit or push unless explicitly requested.
