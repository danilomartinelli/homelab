# cloud-init is not optional on this image.
#
# The provider boots the machine through cloud-init: `systemctl is-active
# cloud-init` reports active on the stock system, and multi-user.target
# wants four of its units — cloud-init-local, cloud-init, cloud-config and
# cloud-final. It reads the `cidata` volume (visible as /dev/sr0) and is
# what writes /etc/systemd/network/10-cloud-init-eth0.network, seeds host
# keys, and grows the root filesystem.
#
# A configuration that omits `services.cloud-init` therefore does not
# "leave the provider's setup alone" — it deletes it. This is the piece
# that was missing while three separate networking theories were being
# tested, each of which addressed a symptom rather than the cause.
#
# `network.enable = true` hands addressing to cloud-init instead of
# declaring it statically here. That reproduces the stock arrangement
# exactly: cloud-init writes the .network file, systemd-networkd applies
# it, dhcpcd never runs.

{ config, pkgs, lib, ... }:
{
  services.cloud-init = {
    enable = true;
    network.enable = true;
  };

  # cloud-init drives systemd-networkd; make the choice explicit so the
  # NixOS default (useDHCP = true, which starts dhcpcd) cannot creep back in.
  networking.useDHCP = false;
  systemd.network.enable = true;
  services.resolved.enable = true;
}
