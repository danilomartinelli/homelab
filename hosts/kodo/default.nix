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
