# modules/backup.nix — Restic backup for service configs
#
# Backs up service config directories to two destinations:
#   - Onsite:  erebor NFS share  (/var/backup/erebor/<hostname>)
#   - Offsite: Cloudflare R2 bucket (homelab-backup/<hostname>)
#
# Usage: set homelab.backup.paths in each host config.
#
# Required sops secrets (add to secrets/<host>.yaml):
#   restic_password   — encryption password for both repos
#   restic_r2_env     — env file with R2 API credentials:
#                         AWS_ACCESS_KEY_ID=...
#                         AWS_SECRET_ACCESS_KEY=...
#
# Alerting:
#   - OnSuccess/OnFailure: ntfy push on every backup run result
#   - restic-freshness-check.timer: daily dead-man's switch (runs at 12:00).
#     Queries InactiveEnterTimestamp on both backup services — this timestamp
#     only updates on *successful* completion (failures enter "failed" state,
#     not "inactive"), so it tracks "time since last successful backup."
#     Fires a high-priority ntfy alert if either repo hasn't succeeded in >36h.

{ config, pkgs, lib, r2AccountId, ... }:

let
  ntfyUrl = "http://10.0.1.9:2586/homelab";
  host    = config.networking.hostName;

  curlBase = "${pkgs.curl}/bin/curl -s "
    + "--connect-timeout 5 --max-time 30 --retry 3 --retry-delay 10 --retry-all-errors ";

  notifyService = { name, description, title, priority, tags, body }: {
    inherit description;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = curlBase
        + "-H 'Title: ${title}' "
        + "-H 'Priority: ${toString priority}' "
        + "-H 'Tags: ${tags}' "
        + "-d '${body}' "
        + ntfyUrl;
    };
  };
in

{
  options.homelab.backup.paths = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    description = "Paths to back up with restic (onsite + offsite).";
  };

  config = lib.mkIf (config.homelab.backup.paths != []) {

    # NFS client support (idempotent — pirateship already has this)
    boot.supportedFilesystems = [ "nfs" ];
    services.rpcbind.enable = true;

    fileSystems."/var/backup/erebor" = {
      device = "erebor.theshire.io:/var/nfs/shared/backups";
      fsType = "nfs";
      options = [ "_netdev" "nofail" "x-systemd.automount" "noauto" ];
    };

    sops.secrets.restic_password = {};
    sops.secrets.restic_r2_env = {};

    # ---------------------------------------------------------------------------
    # Backup run notifications (Option 1 — ntfy on success/failure)
    # ---------------------------------------------------------------------------

    systemd.services.restic-backups-local = {
      unitConfig.OnSuccess = "restic-local-notify-success.service";
      unitConfig.OnFailure = "restic-local-notify-failure.service";
    };

    systemd.services.restic-backups-offsite = {
      unitConfig.OnSuccess = "restic-offsite-notify-success.service";
      unitConfig.OnFailure = "restic-offsite-notify-failure.service";
    };

    systemd.services.restic-local-notify-success = notifyService {
      name        = "restic-local-notify-success";
      description = "Notify ntfy of successful local backup";
      title       = "Backup OK (local)";
      priority    = 1;  # min — informational, no push
      tags        = "floppy_disk";
      body        = "${host} local backup completed successfully";
    };

    systemd.services.restic-local-notify-failure = notifyService {
      name        = "restic-local-notify-failure";
      description = "Notify ntfy of failed local backup";
      title       = "Backup FAILED (local)";
      priority    = 4;  # high
      tags        = "rotating_light";
      body        = "${host} local backup FAILED — check journalctl -u restic-backups-local";
    };

    systemd.services.restic-offsite-notify-success = notifyService {
      name        = "restic-offsite-notify-success";
      description = "Notify ntfy of successful offsite backup";
      title       = "Backup OK (offsite)";
      priority    = 1;  # min — informational, no push
      tags        = "floppy_disk";
      body        = "${host} offsite backup completed successfully";
    };

    systemd.services.restic-offsite-notify-failure = notifyService {
      name        = "restic-offsite-notify-failure";
      description = "Notify ntfy of failed offsite backup";
      title       = "Backup FAILED (offsite)";
      priority    = 4;  # high
      tags        = "rotating_light";
      body        = "${host} offsite backup FAILED — check journalctl -u restic-backups-offsite";
    };

    # ---------------------------------------------------------------------------
    # Freshness dead-man's switch (Option 3 — self-hosted, no external deps)
    #
    # InactiveEnterTimestamp only updates when a oneshot service exits cleanly
    # (success → inactive; failure → failed state, timestamp unchanged).
    # So this check tracks "last successful run," not merely "last attempt."
    # Fires if either repo hasn't succeeded in >36h (catches repeated failures
    # AND timer/configuration issues that prevent the service from running).
    # ---------------------------------------------------------------------------

    systemd.services.restic-freshness-check = {
      description = "Check that restic backups ran recently";
      serviceConfig.Type = "oneshot";
      script = ''
        MAX_AGE_HOURS=36

        check() {
          local unit="$1" label="$2"
          local ts
          ts=$(${pkgs.systemd}/bin/systemctl show "$unit" \
               --property=InactiveEnterTimestamp --value)

          if [ -z "$ts" ] || [ "$ts" = "n/a" ]; then
            ${pkgs.curl}/bin/curl -s \
              --connect-timeout 5 --max-time 30 \
              -H "Title: Backup Never Ran ($label)" \
              -H "Priority: 4" \
              -H "Tags: rotating_light" \
              -d "${host} $label backup has never completed successfully" \
              ${ntfyUrl}
            return
          fi

          local last_epoch now_epoch age_hours
          last_epoch=$(${pkgs.coreutils}/bin/date -d "$ts" +%s 2>/dev/null) || return
          now_epoch=$(${pkgs.coreutils}/bin/date +%s)
          age_hours=$(( (now_epoch - last_epoch) / 3600 ))

          if [ "$age_hours" -gt "$MAX_AGE_HOURS" ]; then
            ${pkgs.curl}/bin/curl -s \
              --connect-timeout 5 --max-time 30 \
              -H "Title: Backup Stale ($label)" \
              -H "Priority: 4" \
              -H "Tags: rotating_light" \
              -d "${host} $label backup stale: last success ''${age_hours}h ago" \
              ${ntfyUrl}
          fi
        }

        check restic-backups-local.service   "local"
        check restic-backups-offsite.service "offsite"
      '';
    };

    systemd.timers.restic-freshness-check = {
      description = "Daily check that restic backups ran recently";
      wantedBy    = [ "timers.target" ];
      timerConfig = {
        OnCalendar          = "12:00";
        RandomizedDelaySec  = "15m";
        Persistent          = true;
      };
    };

    # ---------------------------------------------------------------------------
    # Restic repos
    # ---------------------------------------------------------------------------

    services.restic.backups = {

      local = {
        initialize = true;
        paths = config.homelab.backup.paths;
        repository = "/var/backup/erebor/${config.networking.hostName}";
        passwordFile = config.sops.secrets.restic_password.path;
        timerConfig = {
          OnCalendar = "03:00";
          RandomizedDelaySec = "1h";
        };
        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 12"
        ];
      };

      offsite = {
        initialize = true;
        paths = config.homelab.backup.paths;
        repository = "s3:https://${r2AccountId}.r2.cloudflarestorage.com/homelab-backup/${config.networking.hostName}";
        passwordFile = config.sops.secrets.restic_password.path;
        environmentFile = config.sops.secrets.restic_r2_env.path;
        timerConfig = {
          OnCalendar = "04:00";
          RandomizedDelaySec = "1h";
        };
        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 12"
        ];
      };
    };
  };
}
