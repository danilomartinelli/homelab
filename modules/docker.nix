# Docker daemon + Compose. The daemon listens on the Tailscale interface
# only (and the local socket for the deploy user). No public port, no
# Docker socket in the host's group except for members of the docker
# group (admin, deploy).

{ config, pkgs, lib, ... }:
{
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
    daemon.settings = {
      # No live-restore; reboots are fine, the issue is the daemon holding
      # onto stale container state.
      log-driver = "json-file";
      log-opts = {
        "max-size" = "10m";
        "max-file" = "5";
      };
    };
  };

  # docker-compose v2 from the docker-cli package.
  environment.systemPackages = with pkgs; [
    config.virtualisation.docker.package
  ];

  # Allow the admin user to manage containers without sudo. The deploy user
  # also belongs to the group so unattended restarts work.
  users.users.admin.extraGroups = [ "docker" ];
  users.users.deploy.extraGroups = [ "docker" ];
}
