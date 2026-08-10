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

      # Consumed by the hermes container as an env_file. Docker reads the
      # path from the host, so the secret has to be world-readable at the
      # directory level — hence mode 0400 on the file but a fixed path
      # rather than the default /run/secrets/<name> which is 0700 root.
      #
      # 0440 with group "keys" lets the docker daemon (running as root)
      # read it while keeping it off-limits to unprivileged users.
      "hermes/env" = {
        mode = "0440";
        group = "keys";
      };

      # The seven WHATSAPP_CLOUD_* values, kept separate from hermes/env so
      # the systemd unit can gate on this file's existence. `gateway run`
      # exits 0 when no messaging platform is configured, which Docker's
      # restart policy turns into an invisible loop; making "is WhatsApp
      # configured?" a filesystem question lets ConditionPathExists answer it.
      "hermes/whatsapp-cloud-env" = {
        mode = "0440";
        group = "keys";
      };
    };
  };
}
