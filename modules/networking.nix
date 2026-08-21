# Firewall only. Addressing belongs to cloud-init (see cloud-init.nix).
#
# ANTI-PATTERN — three outages came from this file:
#
#   1. `networking.useDHCP = true`      — explicit DHCP on a static host
#   2. static systemd.network.networks  — fought cloud-init for the same file
#   3. omitting the module entirely     — applied the NixOS default, which
#                                          is useDHCP = true, starting dhcpcd
#
# The tell is always the same line in activation output:
#     the following new units were started: dhcpcd.service
# If dhcpcd appears, addressing is being displaced.
#
# `nixos-rebuild test` cannot validate a network change: the established
# SSH session survives activation, so a broken configuration looks healthy
# until the next boot. Verify from a NEW connection
# (`ssh -o ControlPath=none`) and treat a surviving session as no evidence.

{ config, pkgs, lib, ... }:
{
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    allowedUDPPorts = [
      443   # HTTP/3 for the Uncloud-managed Caddy ingress
      51820 # Uncloud WireGuard mesh
      41641 # Tailscale
    ];
    trustedInterfaces = [ "tailscale0" ];
  };
}
