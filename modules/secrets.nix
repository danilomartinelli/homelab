# SOPS integration. The repo owns the encrypted secrets; the running
# machine decrypts them at activation time. The age public key fingerprint
# in .sops.yaml must match the key on the server.

{ config, pkgs, lib, ... }:
{
  sops = {
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile = ./../secrets/services.yaml;

    # Map logical secret names to file paths. NixOS materializes them
    # under /run/secrets/<name> at boot and to the declared paths below.
    secrets = {
      "ssh/admin/keys" = {
        sopsFile = ./../secrets/services.yaml;
        path = "/etc/ssh/authorized_keys/admin";
        owner = "root";
        group = "root";
        mode = "0600";
      };
      "tailscale/authkey" = {
        sopsFile = ./../secrets/services.yaml;
        path = "/etc/tailscale/authkey";
        owner = "root";
        group = "root";
        mode = "0600";
      };
    };
  };
}
