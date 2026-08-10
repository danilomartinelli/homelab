# kodo — Hostinger KVM 8 (GRU): 8 vCPU, 32GB RAM, 400GB disk, BIOS boot.
#
# Slice 1: users, hostname, kernel params. Nothing that touches networking,
# containers, or the firewall. Each later slice is added and rebooted on its
# own so a boot failure has exactly one candidate cause.

{ config, pkgs, lib, ... }:
{
  imports = [ ./hardware-configuration.nix ];

  # BIOS boot: the running kernel reports BOOT_IMAGE=(hd0,msdos1) and
  # /sys/firmware/efi does not exist, so GRUB goes on the MBR of /dev/sda.
  # There is no ESP; systemd-boot is not an option on this machine.
  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
  };

  # Transcribed from the stock image's /proc/cmdline. The serial console
  # entries are the difference between a diagnosable boot failure and a
  # blank VNC screen — without them the kernel writes to a console nobody
  # is watching.
  boot.kernelParams = [
    "console=tty0"
    "console=ttyS0,115200"
    "earlyprintk=ttyS0,115200"
    "consoleblank=0"
    "memhp_default_state=online"
  ];

  # Both of these exist on the stock image and were found by diffing the
  # built closure's systemd units against the running system — not by
  # reasoning about what a VPS "should" have. growPartition emits
  # growpart.service (WantedBy=-.mount, ordered Before systemd-growfs-root)
  # which expands the root partition to the full disk; qemuGuest emits the
  # agent the hypervisor uses for graceful shutdown and introspection.
  boot.growPartition = true;
  services.qemuGuest.enable = true;

  # Service data root. Compose stacks live under /var/lib/homelab/<name>/
  # and modules/backup.nix lists it as a backup path.
  #
  # It has to be created declaratively: restic skips a nonexistent path
  # SILENTLY — no warning, no non-zero exit. The first backup run looked
  # successful while covering only /etc, which is the failure mode a backup
  # must never have. Verify coverage with `restic snapshots` and check the
  # Paths column, not just the exit status.
  systemd.tmpfiles.rules = [
    "d /var/lib/homelab 0750 root root -"
    # Hermes state. /opt/data inside the container maps here, so it holds
    # config.yaml, auth.json (Codex OAuth), sessions, memories, skills and
    # the Baileys WhatsApp session. 0700 because auth.json is a credential.
    "d /var/lib/homelab/hermes 0700 root root -"
    "d /var/lib/homelab/hermes/data 0700 root root -"
    "d /var/lib/homelab/hermes/data/downloads 0755 root root -"
    "d /var/lib/homelab/hermes/chromium-config 0700 root root -"
  ];

  # Compose stacks are referenced straight out of the Nix store rather than
  # copied to /var/lib. The store path changes when the file changes, so
  # `nixos-rebuild switch` swaps the definition atomically and there is no
  # second copy to drift. Bind-mount sources in the compose files are
  # absolute, so `docker compose` resolving relative paths against the store
  # directory is not a problem.
  #
  # -p pins the project name: without it Compose derives one from the
  # directory, which here is a store hash that changes on every edit and
  # would orphan the previous containers.
  systemd.services = let
    composeService = name: file: {
      description = "homelab ${name}";
      after = [ "docker.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      requires = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.docker}/bin/docker compose -p ${name} -f ${file} up -d --remove-orphans";
        ExecStop = "${pkgs.docker}/bin/docker compose -p ${name} -f ${file} down";
        # Image pulls on a cold start are slow; the default 90s is not enough.
        TimeoutStartSec = "10min";
        TimeoutStopSec = "2min";
      };
    };
  in {
    # Chromium first: Hermes reads HERMES_BROWSER_CDP_URL at startup, so the
    # CDP endpoint should already be listening. This is ordering, not a hard
    # dependency — Hermes tolerates the browser being absent and only fails
    # the browser toolset.
    hermes-chromium = composeService "hermes-chromium" ../../services/hermes-chromium/docker-compose.yml;

    hermes = (composeService "hermes" ../../services/hermes/docker-compose.yml) // {
      after = [ "docker.service" "network-online.target" "hermes-chromium.service" ];

      # Two preconditions, both of which produce a silent restart loop when
      # unmet rather than a useful error:
      #
      #   /run/secrets/hermes/env — materialised by sops-nix during
      #   activation. Compose aborts on a missing env_file.
      #
      #   /run/secrets/hermes/whatsapp-cloud-env — the seven
      #   WHATSAPP_CLOUD_* values. `gateway run` logs "No messaging platforms
      #   enabled" and exits 0 when no channel is configured, which Docker's
      #   restart policy turns into the same silent loop. Gating on the
      #   secret's existence keeps the unit inactive until WhatsApp is
      #   actually configured.
      #
      # Note this replaced a condition on $HERMES_HOME/whatsapp/session,
      # which is where the *Baileys* bridge stores its QR-paired session.
      # The Cloud API never creates that directory, so the old condition
      # would have blocked the unit forever — and the symptom would have
      # looked like a systemd fault rather than a stale precondition.
      #
      # ConditionPathExists makes systemd skip the unit (inactive, not
      # failed) instead of looping, so `systemctl status hermes` reads as a
      # missing precondition rather than a crash.
      unitConfig.ConditionPathExists = [
        "/run/secrets/hermes/env"
        "/run/secrets/hermes/whatsapp-cloud-env"
      ];
    };
  };

  system.stateVersion = "26.05";

  networking.hostName = "kodo";
  networking.domain = "witek.sh";

  time.timeZone = "America/Sao_Paulo";
  i18n.defaultLocale = "en_US.UTF-8";

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };

  environment.systemPackages = with pkgs; [
    vim
    htop
    git
    curl
    jq
  ];
}
