# Users + SSH access. The `admin` user has passwordless sudo and is the only
# human account. The `deploy` user owns /var/lib/homelab and runs services.
# Public keys are loaded from the secrets file so the actual key material
# never lives in the dotfiles repo.

{ config, pkgs, lib, ... }:
let
  sshKeys = config.sops.placeholder."ssh/admin/keys";
in
{
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    openssh.authorizedKeys.keys = sshKeys;
  };

  users.users.deploy = {
    isNormalUser = true;
    home = "/var/lib/homelab";
    createHome = true;
    shell = pkgs.bash;
    description = "Service account for homelab containers";
  };

  # Passwordless sudo for the admin group (wheel). The server is only
  # reachable via Tailscale, which is itself gated on the user's account, so
  # the threat model tolerates this convenience.
  security.sudo.wheelNeedsPassword = false;

  # Lock the root account.
  users.mutableUsers = false;
}
