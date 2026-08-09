# Hardware configuration for kodo (Hostinger KVM 8).
#
# NOT the raw output of `nixos-generate-config`. That generator emits:
#
#     fileSystems."/" = {
#       device = "/dev/disk/by-uuid/f222513b-ded1-49fa-b591-20ce86a2fe7f";
#       fsType = "ext4";
#     };
#
# which drops the mount options the provider image actually boots with.
# The stock /etc/fstab reads:
#
#     /dev/disk/by-label/nixos / ext4 x-systemd.growfs,x-initrd.mount 0 1
#
# `x-systemd.growfs` is what expands the partition to the full disk.
#
# `x-initrd.mount` is deliberately NOT listed: NixOS adds it automatically
# for the root filesystem. Listing it explicitly emitted a duplicated
# option in the generated fstab, which is how the assumption was caught —
# by diffing `result/etc/fstab` against the running system rather than
# reasoning about it.
#
# Transcribed from the running image instead of regenerated, so a rebuild
# cannot silently diverge from what is known to boot.

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot.initrd.availableKernelModules = [
    "ata_piix"
    "uhci_hcd"
    "virtio_pci"
    "virtio_scsi"
    "sd_mod"
    "sr_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    options = [ "x-systemd.growfs" ];
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
