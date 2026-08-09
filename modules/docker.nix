# Docker daemon + Compose. Group membership for admin/deploy is declared
# in users.nix; enabling the daemon here provides the docker CLI and
# compose plugin system-wide.

{ config, pkgs, lib, ... }:
{
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
    daemon.settings = {
      log-driver = "json-file";
      log-opts = {
        "max-size" = "10m";
        "max-file" = "5";
      };
    };
  };
}
