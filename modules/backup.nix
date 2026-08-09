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
  #
  # Bare `restic` is unusable by hand: it needs the repository URL, the
  # password file and both R2 credentials exported first, and without them
  # it fails with "Please specify repository location". That friction is a
  # real hazard — a backup nobody inspects is a hypothesis, not a backup.
  # `kodo-restic` loads the same secrets the timer uses and forwards its
  # arguments, so checking coverage is one command:
  #
  #   kodo-restic snapshots      # verify the Paths column, not just exit 0
  #   kodo-restic check          # verify repository integrity
  #   kodo-restic restore latest --target /tmp/restore-test
  #
  # Requires root: the secrets under /run/secrets are mode 0400 root-owned.
  environment.systemPackages = [
    pkgs.restic
    (pkgs.writeShellScriptBin "kodo-restic" ''
      set -euo pipefail

      if [ "$(id -u)" -ne 0 ]; then
        echo "kodo-restic: must run as root (secrets are root-only)" >&2
        exit 1
      fi

      RESTIC_REPOSITORY="$(cat ${config.sops.secrets."restic/repository".path})"
      export RESTIC_REPOSITORY
      export RESTIC_PASSWORD_FILE=${config.sops.secrets."restic/password".path}

      # r2-env is a systemd EnvironmentFile: plain KEY=VALUE lines.
      set -a
      # shellcheck disable=SC1091
      . ${config.sops.secrets."restic/r2-env".path}
      set +a

      exec ${pkgs.restic}/bin/restic "$@"
    '')
  ];
}
