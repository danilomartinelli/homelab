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
│   ├── rollout.sh                  # Shared deploy + healthcheck safety boundary
│   ├── rollout-host-check.sh       # Nix-installed host health adapter
│   └── rollout-mock-test.sh        # Offline rollout safety checks
├── services/hermes/
│   ├── config.yaml                 # Read-only managed Hermes policy
│   └── docker-compose.yml          # Pinned image and gateway runtime
└── .sops.yaml                      # age recipients for secrets/
```

## Deploying

```sh
scripts/rollout.sh deploy kodo.witek.sh
```

`scripts/rollout.sh deploy [host] [--approve-closure-diff <sha>]` is the
canonical rollout interface. It requires a clean local `main` equal to
`origin/main` and a clean Git checkout at `/etc/homelab`. After fetching, it
freezes the exact
`origin/main` SHA, requires the remote fetch to produce that same SHA, and
deploys the SHA rather than a moving branch. It builds and diffs the closure,
and any ordinary closure difference blocks before `test` unless it is
explicitly acknowledged with the same frozen SHA:

```sh
scripts/rollout.sh deploy kodo.witek.sh --approve-closure-diff <frozen-origin-main-sha>
```

The approval is noninteractive and stale or mismatched SHAs are rejected. The
rollout creates a temporary detached Git worktree at that exact SHA, verifies
both its commit and cleanliness, and evaluates `.#kodo` only from that
immutable committed source. The remote tracked checkout is checked for
cleanliness again after fast-forward and before building; a change at either
boundary aborts before activation. After `readlink -f result` captures the
canonical closure identity, the temporary worktree is removed, and that
immutable store path is used for both `switch-to-configuration test` and
`switch-to-configuration boot`; it never re-evaluates the mutable `.#kodo`
worktree during activation. `test` changes the running system only. Before
calling the candidate's `boot` activation, the rollout registers that exact
closure with `nix-env -p /nix/var/nix/profiles/system --set` and verifies the
canonical system profile points to it; this preserves NixOS generation history
and rollback tooling when boot configuration is invoked directly. The direct
`boot` activation installs the bootloader entry for the same closure but does
not itself update `/run/current-system`; reboot selects the registered boot
generation. The rollout asserts that `/run/current-system` resolves to the
exact captured path
after test activation, after boot, and after reboot, and verifies the profile
again after reboot before accepting the corresponding host health checks. An
unapproved difference prints the complete diff and candidate closure identity
before refusing, and never activates. It then verifies the declared host
adapter from a fresh SSH connection, captures the pre-reboot boot ID, requires
an acknowledged reboot schedule and a changed boot ID, and checks the frozen
checkout again after the host returns. It uses `~/.ssh/id_ed25519` by default;
override that with
`HOMELAB_SSH_KEY`.

The safety paths can be exercised offline with controlled fake SSH, Git, Nix,
activation, reboot, and health commands; no source-text-only expectations are
used. The test covers diff exits 0/1/>1, visible unapproved diff and candidate
identity with no activation, closure approval binding, rejection of a dirty
remote checkout after fast-forward, immutable worktree source and cleanup,
revision and current-system mismatch aborts, reboot receipt and boot-ID
failures, and a wrong post-reboot generation:

```sh
scripts/rollout-mock-test.sh
```

Run the canonical healthcheck phase through the same interface:

```sh
scripts/rollout.sh healthcheck kodo.witek.sh
```

`hosts/kodo/default.nix` installs `homelab-rollout-check` as the host adapter.
Its `test` phase checks the minimum services safe after
`switch-to-configuration test`,
its `reboot` phase adds Hermes readiness and managed STT policy, and its
`healthcheck` phase reports disk, service, Hermes, backup coverage, and
Tailscale status. The local rollout code owns sequencing; the Nix host owns
the facts it can safely observe.

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
system.** Not the parts you suspect. All of it. The rollout does this
automatically and fails closed on differences; the explicit SHA-bound approval
above is required only after reviewing every reported difference:

```sh
nixos-rebuild build --flake .#kodo

diff <(ls /run/current-system/etc/systemd/system/ | sort) \
     <(ls result/etc/systemd/system/ | sort)

diff <(ls /run/current-system/etc/systemd/system/multi-user.target.wants/ | sort) \
     <(ls result/etc/systemd/system/multi-user.target.wants/ | sort)

diff <(cat /run/current-system/kernel-params) <(cat result/kernel-params)
```

Lines prefixed `<` are units the new configuration drops. Each one is a
potential outage. Lines prefixed `>` are intended additions. Without the
explicit SHA-bound approval, any difference blocks activation; approval does
not claim that an unreviewed difference is safe.

This check found `cloud-init`, `growpart.service`, `qemu-guest-agent` and
`-.mount.wants` in a single pass — after four rounds of reasoning had found
none of them.

### Verification order

1. `nixos-rebuild build` — produces `./result`, changes nothing
2. Diff the closure against `/run/current-system` (above)
3. `switch-to-configuration test` on the captured closure — activates without touching the bootloader
4. **Verify from a NEW connection:** `ssh -o ControlPath=none root@kodo …`
5. `switch-to-configuration boot` on the same captured closure, then reboot, then verify the boot ID and exact generation again

Step 4 is not optional. `switch-to-configuration test` keeps the current SSH session
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
2. Add a `homelab.compose.stacks.<name>` entry in `hosts/kodo/default.nix`,
   including its Compose `file` and explicit `projectName`
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

## WhatsApp Cloud webhook intake

The public callback and the private listener are one configuration contract.
Keep the values below synchronized when changing the route; the callback URL
is the value entered in Meta, while the bind and ingress settings are managed
in this repository.

| Layer | Source of truth | Required value |
|---|---|---|
| Provider callback URL | Meta webhook configuration | `https://hermes.witek.sh/whatsapp/webhook` |
| Hermes listener | `services/hermes/docker-compose.yml` | `10.210.0.1:8090`, path `/whatsapp/webhook` |
| Public ingress matcher | `services/uncloud/Caddyfile` | `handle /whatsapp/webhook*` |
| Public ingress upstream | `services/uncloud/Caddyfile` | `10.210.0.1:8090` |
| Host firewall permission | `modules/ingress.nix` | `networking.firewall.allowedTCPPorts` includes `8090` |

The listener is intentionally bound to the Uncloud bridge gateway, not to a
public or Tailscale interface. Caddy is the separately deployed public
ingress. The host firewall allows the internal port so that Caddy can reach
it; it does not replace the Caddy route or make the listener a public
endpoint. If the listener port changes, update the Compose bind, Caddy
upstream, and `networking.firewall.allowedTCPPorts` in `modules/ingress.nix`
together. If the path changes, update the Compose path, Caddy matcher, and
provider callback URL together.

### Configuration ownership

- **Provider credentials:** edit the encrypted `hermes.whatsapp-cloud-env`
  value in `secrets/services.yaml` with `sops secrets/services.yaml`. It must
  contain these keys, with no values committed here:

  ```text
  WHATSAPP_ENABLED
  WHATSAPP_MODE
  WHATSAPP_CLOUD_ACCESS_TOKEN
  WHATSAPP_CLOUD_APP_ID
  WHATSAPP_CLOUD_APP_SECRET
  WHATSAPP_CLOUD_PHONE_NUMBER_ID
  WHATSAPP_CLOUD_WABA_ID
  WHATSAPP_CLOUD_VERIFY_TOKEN
  WHATSAPP_CLOUD_ALLOWED_USERS
  ```

  `WHATSAPP_CLOUD_ALLOWED_USERS` is an authorized inbound sender/user
  allow-list controlling which WhatsApp users may interact with Hermes; it is
  not a recipient allow-list. Keep it restricted so unknown senders remain
  denied, and never use an allow-all setting. Do not create or use
  `services/.env`; the tracked generic key reference is
  `services/.env.example`, which intentionally contains no WhatsApp secrets.
- **Runtime bind and path:** the three
  `WHATSAPP_CLOUD_WEBHOOK_*` settings remain non-secret Compose environment
  settings in `services/hermes/docker-compose.yml`.
- **Public ingress:** the hostname, path matcher and reverse-proxy upstream
  remain in `services/uncloud/Caddyfile`. Use the synchronized port and path
  change procedure above as one reviewable change; do not silently change
  only one configuration surface.

### Setup and operations

1. Ensure authoritative DNS for `hermes.witek.sh` resolves to the public
   ingress IPv4 `187.77.229.230`. DNS alone does not route a container; the
   Caddy service must also have the route above deployed.
2. Put the provider values in the separate SOPS key described above. Hermes
   requires both `/run/secrets/hermes/env` and
   `/run/secrets/hermes/whatsapp-cloud-env`; the first contains the general
   Hermes environment and the second contains the WhatsApp Cloud values.
3. Deploy the host repository with the existing guarded operation:

   ```sh
   scripts/deploy.sh kodo.witek.sh
   ```

   This is the existing NixOS host deployment and does not deploy Caddy.
   Reapply Caddy separately when its tracked configuration changes:

   ```sh
   uc caddy deploy -c loopdodia \
     --image caddy:2.10.2 \
     --caddyfile services/uncloud/Caddyfile
   ```

4. In Meta, enter the canonical callback URL and use the same value as
   `WHATSAPP_CLOUD_VERIFY_TOKEN` for the provider's verification token. Use
   Meta's current UI to complete the webhook subscription; this repository
   deliberately does not assert provider-specific field names.

### Layered verification and diagnosis

Check the static contract without exposing secret values:

```sh
git diff --check
grep -nE 'WHATSAPP_CLOUD_WEBHOOK_|/whatsapp/webhook|10\.210\.0\.1:8090' \
  services/hermes/docker-compose.yml services/uncloud/Caddyfile
```

On `kodo`, check prerequisites and container health separately:

```sh
sudo systemctl status hermes --no-pager
sudo systemctl show hermes -p ActiveState -p SubState -p ConditionResult
sudo ls -l /run/secrets/hermes/env /run/secrets/hermes/whatsapp-cloud-env
sudo docker inspect --format '{{.State.Status}}/{{.State.Health.Status}}' hermes
```

If either secret path is absent, `ConditionPathExists` skips `hermes` at a
systemd start attempt, leaving it inactive rather than starting a restart
loop. It checks only path existence: empty or malformed files still satisfy
the condition, and removing a path after startup does not continuously stop
an already-started unit. Check both paths and the SOPS activation log before
changing Compose or networking:

```sh
sudo journalctl -u sops-install-secrets -b --no-pager
```

An active systemd unit and a healthy Hermes container prove only local
process/container health. They do not prove DNS, TLS, public Caddy routing,
or Meta verification. Complete the provider's verification flow and inspect
the existing Caddy and Hermes logs for the corresponding request; do not use
a generic HTTP response as a substitute for provider-side verification.

### Security boundaries

- Use a permanent Meta System User access token, not the 24-hour dashboard
  quickstart token.
- `WHATSAPP_CLOUD_PHONE_NUMBER_ID` is Meta's opaque phone-number ID, not the
  dialable telephone number.
- Choose a verify token and keep the provider's value equal to
  `WHATSAPP_CLOUD_VERIFY_TOKEN`; it is not a value issued by Meta.
- Keep `WHATSAPP_CLOUD_ALLOWED_USERS` restricted to the intended digits-only
  inbound users; unknown senders must remain denied. Never enable
  `GATEWAY_ALLOW_ALL_USERS=true`.
- Keep credentials in SOPS and out of the callback URL, `services/.env`, Git,
  and diagnostic output.

Audio transcription is handled once by Hermes' native STT pipeline. The
managed policy pins local CPU/int8 transcription in Portuguese and the image
includes `faster-whisper`; this prevents silent cloud fallback. The retired
`whatsapp-stt` adapter is disabled and moved to the restic-backed
`retired-plugins` directory rather than deleted.

## Uncloud

`kodo` is the first member of the `loopdodia` cluster. Both the local `uc`
client and the server's `uc`/`uncloudd` binaries are pinned to `v0.20.0`;
they must be upgraded together. The client on the Mac connects as
`admin@kodo.witek.sh` using `~/.ssh/id_ed25519`. Only the public key is
declared in `modules/users.nix`. When run by `admin` on kodo, `uc` uses the
local `/run/uncloud/uncloud.sock` through the declarative `loopdodia`
context, so no private SSH key is stored on the server.

The cluster uses these fixed network values:

| Purpose | Value |
|---|---|
| Machine/service network | `10.210.0.0/16` |
| `kodo` subnet | `10.210.0.0/24` |
| Host gateway from Uncloud containers | `10.210.0.1` |
| Public ingress | `187.77.229.230` |
| WireGuard endpoint | `187.77.229.230:51820/udp` |
| Reserved Uncloud domain | `*.7a57lb.uncld.dev` |

Uncloud containers use the machine gateway (`10.210.0.1`) as their DNS
server. The host firewall therefore permits TCP and UDP port 53 only on
Docker's user-defined bridge interfaces (`br-*`). Do not replace the
container DNS with a public resolver: doing so would make public names work
but break Uncloud service discovery through `*.internal`.

`uc dns reserve` reserves only the optional Uncloud-managed
`<cluster-id>.uncld.dev` domain. It does not register or manage
`loopdodia.dev`; custom domains remain in their authoritative DNS provider
and must also be declared as ingress endpoints for the destination service.

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
