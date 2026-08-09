# restic backups to Cloudflare R2.
#
# restic encrypts and deduplicates locally before uploading, so R2 never
# sees plaintext and the bucket does not need to be trusted. What must be
# protected is RESTIC_PASSWORD: lose it and the backups are unrecoverable,
# because there is no key escrow. It lives in sops alongside the R2
# credentials.
#
# R2 speaks the S3 API, so the repository URL is:
#   s3:https://<account-id>.r2.cloudflarestorage.com/<bucket>
# and credentials arrive as AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
# through environmentFile.
#
# R2 charges no egress, which matters for restores: pulling a full backup
# out of B2 or S3 costs real money, and a backup you avoid restoring from
# is not a backup.

{ config, pkgs, lib, ... }:
{
  services.restic.backups.kodo = {
    initialize = true;

    repositoryFile = config.sops.secrets."restic/repository".path;
    passwordFile = config.sops.secrets."restic/password".path;
    environmentFile = config.sops.secrets."restic/r2-env".path;

    paths = [
      "/var/lib/homelab"
      "/etc"
    ];

    exclude = [
      "/var/lib/homelab/**/.cache"
      "/var/lib/homelab/**/node_modules"
      "**/.git"
    ];

    timerConfig = {
      OnCalendar = "daily";
      # Run after a missed window (a reboot, a powered-off machine) instead
      # of silently skipping until the next day.
      Persistent = true;
      RandomizedDelaySec = "30m";
    };

    # Retention is applied by `restic forget --prune` after each run.
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 6"
    ];
  };

  # restic is also wanted interactively — for `restic snapshots`, restores,
  # and integrity checks. The service brings its own copy, but not onto PATH.
  environment.systemPackages = [ pkgs.restic ];
}
