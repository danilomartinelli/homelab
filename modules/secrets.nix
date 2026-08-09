# sops-nix wiring.
#
# The machine decrypts its own secrets using an age key derived from its SSH
# host key (see .sops.yaml), so no key material has to be copied to the
# server. Secrets are materialised under /run/secrets/<name> at activation,
# owned by root and mode 0400 unless overridden.
#
# This module declares NO secrets yet, on purpose. sops-nix fails activation
# if `defaultSopsFile` points at a file that does not exist or cannot be
# decrypted, and an empty secrets file buys nothing. Add entries here in the
# same change that introduces the secret and the service consuming it —
# never ahead of it.
#
# To add one:
#   1. sops secrets/services.yaml          # creates/edits, encrypts on save
#   2. declare it below under sops.secrets
#   3. reference config.sops.secrets.<name>.path from the consuming module
#
# Verify after activation with:
#   ls -l /run/secrets/
# A missing file means activation silently skipped it; check
# `journalctl -u sops-install-secrets`.

{ config, pkgs, lib, ... }:
{
  sops = {
    # Derive the decryption key from the host key rather than shipping an
    # age identity to the machine.
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    # No defaultSopsFile and no secrets while none exist. Setting either
    # ahead of a real secret turns a missing file into a failed activation.
  };
}
