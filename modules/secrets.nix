# sops-nix wiring.
#
# The machine decrypts its own secrets using an age key derived from its SSH
# host key (see .sops.yaml), so no key material has to be copied to the
# server. Secrets are materialised under /run/secrets/<name> at activation,
# owned by root and mode 0400 unless overridden.
#
# ORDERING MATTERS: sops-nix fails activation if defaultSopsFile points at a
# file that does not exist or cannot be decrypted. Do not add this module to
# modules/default.nix until secrets/services.yaml has actually been created
# with `sops secrets/services.yaml`. Declaring secrets ahead of the file
# turns a missing input into a failed rebuild.
#
# Verify after activation:
#   ls -l /run/secrets/restic/
#   journalctl -u sops-install-secrets

{ config, pkgs, lib, ... }:
{
  sops = {
    # Derive the decryption key from the host key rather than shipping an
    # age identity to the machine.
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    defaultSopsFile = ../secrets/services.yaml;

    secrets = {
      # Consumed by services.restic.backups.kodo in modules/backup.nix.
      "restic/repository" = { };
      "restic/password" = { };
      "restic/r2-env" = { };
    };
  };
}
