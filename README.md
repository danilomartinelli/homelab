# homelab

Reproducible NixOS configuration for `kodo`, a personal VPS used as a
homelab. Managed from a macOS laptop; this repo is the single source of
truth for what runs on the server.

**Host:** Hostinger KVM 8 in GRU — 8 vCPU, 32 GB RAM, 400 GB disk, BIOS
boot, NixOS 26.05. Reachable at `kodo.witek.sh`.

## Layout

```text
homelab/
├── flake.nix                       # NixOS 26.05 inputs
├── flake.lock                      # Exact production input revisions
├── hosts/kodo/
│   ├── default.nix                 # Host facts: bootloader, kernel params, hostname
│   └── hardware-configuration.nix  # Transcribed from the image, not regenerated
├── modules/
│   ├── users.nix                   # admin + root keys, SSH daemon
│   ├── cloud-init.nix              # Provider boot integration — mandatory
│   ├── networking.nix              # Firewall only; addressing belongs to cloud-init
│   ├── docker.nix                  # Docker daemon and Compose
│   ├── uncloud.nix                 # Pinned uncloudd daemon and systemd unit
│   ├── ingress.nix                 # Public ports for Uncloud Caddy
│   ├── tailscale.nix               # Private administration network
│   ├── secrets.nix                 # SOPS materialisation
│   └── backup.nix                  # Restic backup policy
├── scripts/
│   ├── deploy.sh                   # Safe main -> test -> boot -> reboot deploy
│   └── healthcheck.sh              # Disk / services / backup status
├── services/hermes/
│   ├── config.yaml                 # Read-only managed Hermes policy
│   └── docker-compose.yml          # Pinned image and gateway runtime
└── .sops.yaml                      # age recipients for secrets/
```

## Deploying

```sh
scripts/deploy.sh kodo.witek.sh
```

The script requires a clean local `main` equal to `origin/main` and a clean
Git checkout at `/etc/homelab`. It fast-forwards the server, builds and diffs
the closure, activates it with `test`, verifies a fresh SSH connection, sets
the boot generation, reboots, and checks the core services after the host
returns. It uses `~/.ssh/id_ed25519` by default; override that with
`HOMELAB_SSH_KEY`.

## The rule that matters

This configuration replaces the entire system definition on every rebuild.
It does not merge with whatever the provider image set up. Anything the
image configured and this repo does not declare simply stops existing at
the next boot.

That single fact caused four outages and four reinstalls. Every one of them
looked like a different bug — DHCP, `/etc/shadow`, mount options, a missing
`x-initrd.mount` — and every one had the same cause: something the image
declared and this repo did not.

**Before activating any change, diff the built closure against the running
system.** Not the parts you suspect. All of it:

```sh
nixos-rebuild build --flake .#kodo

diff <(ls /run/current-system/etc/systemd/system/ | sort) \
     <(ls result/etc/systemd/system/ | sort)

diff <(ls /run/current-system/etc/systemd/system/multi-user.target.wants/ | sort) \
     <(ls result/etc/systemd/system/multi-user.target.wants/ | sort)

diff <(cat /run/current-system/kernel-params) <(cat result/kernel-params)
```

Lines prefixed `<` are units the new configuration drops. Each one is a
potential outage. Lines prefixed `>` are intended additions. The diff must
show no `<` lines you cannot explain.

This check found `cloud-init`, `growpart.service`, `qemu-guest-agent` and
`-.mount.wants` in a single pass — after four rounds of reasoning had found
none of them.

### Verification order

1. `nixos-rebuild build` — produces `./result`, changes nothing
2. Diff the closure against `/run/current-system` (above)
3. `nixos-rebuild test` — activates without touching the bootloader
4. **Verify from a NEW connection:** `ssh -o ControlPath=none root@kodo …`
5. `nixos-rebuild boot`, then reboot, then verify again

Step 4 is not optional. `nixos-rebuild test` keeps the current SSH session
alive regardless of whether it just destroyed the network configuration, so
a working session proves nothing. A configuration that breaks networking
looks identical to one that does not until the machine reboots.

Step 3 is the safety net: `test` leaves the bootloader pointing at the last
good generation, so any failure is recoverable with a reboot from the
provider panel — no console needed.

## Known constraints of this image

| Fact | Consequence |
|---|---|
| `/etc/nixos/` is empty | The image's configuration cannot be read; it has to be reconstructed by diffing |
| cloud-init owns networking | Do not declare addresses; declare `services.cloud-init` and let it write the `.network` file |
| Addressing is static, `DHCP=no` | NixOS defaults to `useDHCP = true`; leaving networking undeclared starts dhcpcd and breaks the host |
| BIOS boot, no ESP | GRUB on the MBR of `/dev/sda`; systemd-boot is not available |
| Serial console on `ttyS0` | `boot.kernelParams` must keep `console=ttyS0,115200`, or a failed boot shows a blank screen |

## Pinned inputs

`flake.lock` is committed and is the exact dependency set evaluated in
production. `flake.nix` follows the NixOS 26.05 release branch, but inputs
only move when the lockfile is intentionally updated and reviewed.

Run `nix flake update` deliberately and use the full diff-and-verify sequence
above, because an input update can change the kernel and systemd closure.

## Adding a service

1. Write the compose stack under `services/<name>/` in this repository
2. Add a systemd unit entry in `hosts/kodo/default.nix`
3. Deploy, then verify with an actual reboot

Enable one module at a time. A boot failure with one change has one
candidate cause; with four changes it has four.

## Hermes state boundary

Hermes uses two configuration layers:

- `services/hermes/config.yaml` is the Git-managed, read-only server policy.
  Nix materialises it as `/etc/hermes/config.yaml`, and Hermes deep-merges it
  over the user configuration.
- `/var/lib/homelab/hermes/data` is mutable runtime state mounted at
  `/opt/data`. It holds OAuth, pairings, sessions, memories, personal channel
  IDs, downloaded models and user preferences. It is covered by restic, not
  committed to Git.

Provider keys and WhatsApp credentials remain SOPS-encrypted in
`secrets/services.yaml`; activation materialises them below `/run/secrets`.
The repository must never contain the decrypted `.env`, `auth.json`, session
databases or pairing files.

Audio transcription is handled once by Hermes' native STT pipeline. The
managed policy pins local CPU/int8 transcription in Portuguese and the image
includes `faster-whisper`; this prevents silent cloud fallback. The retired
`whatsapp-stt` adapter is disabled and moved to the restic-backed
`retired-plugins` directory rather than deleted.

## Uncloud

`kodo` is the first member of the `loopdodia` cluster. Both the local `uc`
client and the remote daemon are pinned to `v0.20.0`; they must be upgraded
together. The client connects as `admin@kodo.witek.sh` using
`~/.ssh/id_ed25519`. Only the public key is declared in `modules/users.nix`.

The cluster uses these fixed network values:

| Purpose | Value |
|---|---|
| Machine/service network | `10.210.0.0/16` |
| `kodo` subnet | `10.210.0.0/24` |
| Host gateway from Uncloud containers | `10.210.0.1` |
| Public ingress | `187.77.229.230` |
| WireGuard endpoint | `187.77.229.230:51820/udp` |
| Reserved Uncloud domain | `*.7a57lb.uncld.dev` |

Uncloud's global Caddy service owns `80/tcp`, `443/tcp` and `443/udp`.
Its custom config is versioned at `services/uncloud/Caddyfile` and preserves
the `hermes.witek.sh/whatsapp/webhook` route. Reapply it after intentional
changes with:

```sh
uc caddy deploy -c loopdodia \
  --image caddy:2.10.2 \
  --caddyfile services/uncloud/Caddyfile
```

For `loopdodia.dev`, point both the apex and wildcard at the public IPv4:

```text
loopdodia.dev    A  187.77.229.230
*.loopdodia.dev  A  187.77.229.230
```

Uncloud will then route a hostname only after a deployed service declares
that hostname as an HTTP/HTTPS ingress endpoint. DNS alone does not expose a
container.
