# Per-host NixOS configuration. Most settings live in modules/; this file
# ties them together with the host-specific facts (timezone, locale,
# packages unique to this machine, service definitions).

{ config, pkgs, lib, unstable, ... }:
{
  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
  };

  system.stateVersion = "25.05";

  # Hostname for `hostname` and DHCP; FQDN comes from Tailscale MagicDNS.
  networking = {
    hostName = "homelab";
    hostId = "deadbeef"; # required, change to a stable random hex
  };

  time.timeZone = "America/Sao_Paulo";
  i18n.defaultLocale = "en_US.UTF-8";

  # System packages unique to this host. Keep this list small; the bulk of
  # runtime tooling lives inside Docker containers.
  environment.systemPackages = with pkgs; [
    vim
    htop
    restic
    jq
    git
    curl
  ];

  # Pull in a few newer packages from unstable. Pin via unstable.<pkg>.
  environment.systemPackages = [
    unstable.docker-compose
  ];

  # System services declared in this repo (one stack per subdirectory).
  # Each compose file lives under /var/lib/homelab/<service>/ and is owned
  # by the deploy user. Add a new entry here when you add a new service
  # under /var/lib/homelab/<name>/.
  systemd.services = let
    mkService = name: {
      description = "homelab ${name}";
      after = [ "docker.service" "tailscaled.service" ];
      requires = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        WorkingDirectory = "/var/lib/homelab/${name}";
        User = "deploy";
        Group = "deploy";
        ExecStart = "${pkgs.docker}/bin/docker compose up -d --remove-orphans";
        ExecStop = "${pkgs.docker}/bin/docker compose down";
        TimeoutStartSec = "5min";
        TimeoutStopSec = "1min";
      };
    };
    services = {
      # Add a key here per compose stack you put under /var/lib/homelab/<name>.
      # Example:
      #   caddy = null;
    };
  in lib.mapAttrs' (n: _: lib.nameValuePair "homelab-${n}" (mkService n)) services;
}
