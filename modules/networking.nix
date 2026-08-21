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

    # Uncloud runs its authoritative/forwarding DNS listener on each machine's
    # service-network gateway (10.210.0.1 on kodo). Containers are configured
    # to query that address so both public names and Uncloud's *.internal names
    # resolve. Docker gives user-defined bridges dynamic br-<id> names; the
    # iptables `+` suffix matches all of those bridges without exposing DNS on
    # the host's public interface.
    interfaces."br-+" = {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [ 53 ];
    };
  };
}
