# restic backup to Backblaze B2 (or any S3-compatible backend). The
# repository URL and credentials come from sops so the secrets never
# appear in this file.

{ config, pkgs, lib, ... }:
let
  repo = "b2:homelab-bucket:/restic";
  passwordFile = config.sops.placeholder."restic/password";
  b2KeyFile = config.sops.placeholder."restic/b2-account-key";
  b2IdFile = config.sops.placeholder."restic/b2-account-id";
in
{
  services.restic.backups.homelab = {
    inherit repo;
    passwordFile = passwordFile;
    environmentFile = pkgs.writeText "restic-b2.env" ''
      B2_ACCOUNT_ID_FILE=${b2IdFile}
      B2_ACCOUNT_KEY_FILE=${b2KeyFile}
    '';
    initialize = true;
    paths = [
      "/var/lib/homelab"
      "/etc"
    ];
    exclude = [
      "/var/lib/homelab/.cache"
      "**/.git"
    ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
    pruneOpts = [
      "--keep-daily=7"
      "--keep-weekly=4"
      "--keep-monthly=6"
    ];
  };
}
