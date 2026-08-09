# Tailscale: the intended ingress path once bootstrapped. The auth key is
# applied manually on first boot (`tailscale up --ssh`); once sops secrets
# are wired (see modules/secrets.nix, currently disabled), switch to
# authKeyFile so rebuilds re-join automatically.

{ config, pkgs, lib, ... }:
{
  services.tailscale = {
    enable = true;
    openFirewall = true;
    extraUpFlags = [ "--ssh" ];
  };
}
