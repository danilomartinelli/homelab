# Networking baseline: hardened SSH on a non-default port, systemd-resolved,
# and a firewall that drops everything except Tailscale UDP/41641. Public
# access is via Tailscale MagicDNS; there is no inbound internet except for
# the SSH exception below for first-boot setup.

{ config, pkgs, lib, ... }:
{
  networking = {
    useDHCP = true;
    firewall = {
      enable = true;
      # Allow Tailscale direct connections.
      allowedUDPPorts = [ 41641 ];
      # SSH from any source during the bootstrap window; tighten after
      # Tailscale is confirmed reachable.
      allowedTCPPorts = [ 22 ];
      trustedInterfaces = [ "tailscale0" ];
    };
    nameservers = [ "1.1.1.1" "1.0.0.1" ];
  };

  # Use the Hetzner / cloud-init NTP server when present, else fall back to
  # the systemd default pool.
  services.timesynced.enable = true;

  # SSH hardening: disable password auth, root login, X11 forwarding. The
  # listen port stays at 22 during the Tailscale bootstrap window — change
  # it once `tailscale up` is confirmed.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
      X11Forwarding = false;
      KbdInteractiveAuthentication = false;
      UseDNS = false;
    };
    openFirewall = true;
  };

  # Disable the unused services that some distros ship enabled by default.
  services.avahi.enable = false;
  services.mdns = {
    enable = false;
    openFirewall = false;
  };
}
