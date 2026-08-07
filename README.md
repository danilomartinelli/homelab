# homelab

A reproducible NixOS configuration for a personal VPS used as a homelab.
Long-running AI agents, scheduled jobs, and self-hosted services live
here. Management happens from a parent dotfiles repo on macOS; this repo
is the single source of truth for what runs on the server.

## Layout

```text
homelab/
├── flake.nix              # NixOS 25.05 + unstable overlay + sops-nix
├── hosts/homelab/         # Per-machine config (the only host for now)
├── modules/               # Composable NixOS pieces
│   ├── users.nix          # admin + deploy accounts, passwordless sudo
│   ├── networking.nix     # Hardened SSH, firewall, Tailscale interface trust
│   ├── docker.nix         # Docker daemon + compose v2
│   ├── tailscale.nix      # Tailscale with --ssh operator-bound
│   ├── secrets.nix        # SOPS decryption at activation
│   └── backup.nix         # restic -> Backblaze B2
├── secrets/               # sops-encrypted YAML (gitignored when decrypted)
│   └── services.yaml
├── services/              # Templates only; real config lives in secrets/
├── scripts/
│   ├── bootstrap.sh       # First-boot setup on a fresh VPS
│   ├── deploy.sh          # Apply latest flake to the remote host
│   └── healthcheck.sh     # Print disk / service / backup status
└── .sops.yaml             # SOPS age recipient config
```

## First-time setup

1. **Provision a VPS.** Hetzner CCX23 (€23.50/mo, 4 dedicated vCPU / 8GB)
   is the recommendation. Pick Falkenstein, Helsinki, or Hillsboro.
2. **Point DNS or just wait for Tailscale MagicDNS.** The bootstrap works
   over the public IPv4 — Tailscale joins later.
3. **Generate an age key on your laptop:**
   ```sh
   sops-key-create work
   sops -age /Users/you/.config/sops/age/keys/work/recipient.txt
   ```
4. **Edit `.sops.yaml`** and replace the placeholder `age1...` fingerprint
   with the one you just generated.
5. **Decrypt the secrets template and fill it in:**
   ```sh
   cp services/.env.example secrets/services.yaml
   $EDITOR secrets/services.yaml
   sops encrypt --in-place secrets/services.yaml
   ```
6. **Run bootstrap on the server:**
   ```sh
   ssh root@<server-ip>
   HOMELAB_REPO=https://github.com/danilomartinelli/homelab.git \
     bash scripts/bootstrap.sh
   ```
7. **Activate Tailscale on first login** (the auth key comes from sops):
   ```sh
   sudo tailscale up --ssh
   ```
8. **From your laptop, run the deploy script** for every change:
   ```sh
   scripts/deploy.sh homelab
   ```

## Adding a service

1. Create `/var/lib/homelab/<name>/docker-compose.yml` on the server
   (the `deploy` user owns it).
2. Add a systemd unit entry in `hosts/homelab/default.nix` under
   `services = { <name> = null; };`.
3. Push the flake change via `scripts/deploy.sh`.

## Health check

`scripts/healthcheck.sh homelab` prints disk usage, service status, last
restic snapshot, and the current Tailscale IP. Wire it into a daily cron
or a Uptime Kuma probe if you want alerts.

## Local model configuration

When this host runs AI agents (OpenCode, Codex, etc.), provider keys come
from the laptop's `~/.localrc` (managed by the parent dotfiles repo), not
from this server. Agents running on the server read the same env files
once you `scp` them across or wire them up via 1Password CLI.
