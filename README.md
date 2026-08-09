# homelab

Reproducible NixOS configuration for `kodo`, a personal VPS used as a
homelab. Managed from a macOS laptop; this repo is the single source of
truth for what runs on the server.

**Host:** Hostinger KVM 8 in GRU — 8 vCPU, 32 GB RAM, 400 GB disk, BIOS
boot, NixOS 26.05. Reachable at `kodo.witek.sh`.

## Layout

```text
homelab/
├── flake.nix                       # NixOS 26.05, currently pinned (see below)
├── hosts/kodo/
│   ├── default.nix                 # Host facts: bootloader, kernel params, hostname
│   └── hardware-configuration.nix  # Transcribed from the image, not regenerated
├── modules/
│   ├── users.nix                   # admin + root keys, SSH daemon
│   ├── cloud-init.nix              # Provider boot integration — mandatory
│   ├── networking.nix              # Firewall only; addressing belongs to cloud-init
│   ├── docker.nix                  # (not yet enabled)
│   ├── tailscale.nix               # (not yet enabled)
│   ├── secrets.nix                 # (not yet enabled)
│   └── backup.nix                  # (not yet enabled)
├── scripts/
│   ├── deploy.sh                   # Apply the flake to the remote host
│   └── healthcheck.sh              # Disk / services / backup status
└── .sops.yaml                      # age recipients for secrets/
```

## Deploying

```sh
scripts/deploy.sh kodo
```

That runs `nixos-rebuild switch` on the host over SSH. Read the next
section before trusting it.

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

## Pinned nixpkgs

`flake.nix` currently pins nixpkgs to `21ea275a7c46`, the revision the
provider image ships. The pin was added to remove the kernel from the set
of variables while the deploy pipeline was being proven — it makes the
built kernel byte-identical to the one already known to boot.

The pin is a debugging aid, not a permanent state: it also freezes security
updates. Unpin it back to `github:NixOS/nixpkgs/nixos-26.05` and run the
same diff-and-verify sequence above.

## Adding a service

1. Write the compose stack under `/var/lib/homelab/<name>/` on the host
2. Add a systemd unit entry in `hosts/kodo/default.nix`
3. Deploy, then verify with an actual reboot

Enable one module at a time. A boot failure with one change has one
candidate cause; with four changes it has four.
