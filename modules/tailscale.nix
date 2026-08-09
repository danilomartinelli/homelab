# Tailscale.
#
# Enabling the service starts tailscaled but does NOT join a tailnet: that
# needs an auth key. Rather than wire one through sops now — which would
# make this slice depend on the secrets slice — the machine is joined once
# by hand:
#
#     sudo tailscale up --ssh
#
# That prints a URL to authenticate in a browser. The resulting node key is
# stored in /var/lib/tailscale and survives rebuilds and reboots, so it is a
# one-time step per machine.
#
# `--ssh` enables Tailscale SSH, which authenticates via tailnet identity
# instead of the authorized_keys file. It is additive: the normal sshd on
# port 22 keeps working, so a Tailscale misconfiguration cannot lock you out.
#
# Once secrets.nix is enabled, `authKeyFile` can point at a sops secret so a
# rebuilt machine rejoins unattended. Not worth it for a single host.

{ config, pkgs, lib, ... }:
{
  services.tailscale = {
    enable = true;
    # The UDP port for direct connections is already opened in
    # networking.nix alongside the rest of the firewall policy; keeping it
    # in one place avoids two modules disagreeing about the same rule.
    openFirewall = false;
  };
}
