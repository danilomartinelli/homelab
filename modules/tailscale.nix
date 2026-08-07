# Tailscale: the only ingress path once the server is bootstrapped. The
# auth key comes from sops secrets so we never commit it to the repo.

{ config, pkgs, lib, ... }:
{
  services.tailscale = {
    enable = true;
    useRouting = false;
    useSubnetRouter = false;
    # Auth key is read from sops at activation; placeholder is empty.
    authKeyFile = config.sops.placeholder."tailscale/authkey";
    extraUpFlags = [
      "--ssh"
      "--accept-routes=false"
      "--operator=${config.users.users.admin.name}"
    ];
  };

  # MagicDNS hostname. The full domain becomes <hostname>.tail<hash>.ts.net.
  # The flake owner should set TAILSCALE_HOSTNAME via sops or the host config.
  environment.etc."tailscale/hostname".text = "homelab";
}
