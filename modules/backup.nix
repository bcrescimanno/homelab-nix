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
#     Reads persistent stamp files under /var/lib/homelab-freshness, written by
#     each tracked unit's ExecStopPost only when it exited successfully — so the
#     stamp means "last successful run," not "last attempt."
#     Fires a high-priority ntfy alert if a repo hasn't succeeded in >36h.
#
# Integrity:
#   - Each nightly run ends with `restic check --read-data-subset=10%`, so a
#     corrupt repo fails the unit and trips the OnFailure alert above rather
#     than staying silent until a restore is attempted. See checkOpts below.

{ config, pkgs, lib, r2AccountId, ... }:

let
  ntfyUrl = "http://10.0.1.9:2586/homelab";
  host    = config.networking.hostName;

  curlBase = "${pkgs.curl}/bin/curl -s "
    + "--connect-timeout 5 --max-time 30 --retry 3 --retry-delay 10 --retry-all-errors ";

  # Persistent freshness stamps. systemd's InactiveEnterTimestamp is runtime-only
  # and is wiped on reboot, which made the dead-man's switch report "has never
  # completed successfully" for every tracked unit after any reboot in the window
  # between the nightly jobs and the 12:00 check (observed on rivendell
  # 2026-07-31 — three Priority-4 alarms while the journal showed that morning's
  # runs had all succeeded). A stamp file under /var/lib survives reboots.
  stampDir = "/var/lib/homelab-freshness";

  # Written only when the unit actually succeeded. This deliberately preserves the
  # semantics InactiveEnterTimestamp gave us — "last SUCCESSFUL run", not "last
  # attempt" — so a repeatedly-failing job still goes stale and alerts.
  stampOnSuccess = name: pkgs.writeShellScript "freshness-stamp-${name}" ''
    if [ "$SERVICE_RESULT" = "success" ]; then
      ${pkgs.coreutils}/bin/touch ${stampDir}/${name}
    fi
  '';

  trackedUnits = [ "restic-backups-local" "restic-backups-offsite" "homelab-upgrade-check" ];

  # Repository integrity verification.
  #
  # Until 2026-08-01 checkOpts was unset on both repos. `runCheck` defaults to
  # `length checkOpts > 0`, so it was false — meaning `restic check` had NEVER
  # run against either repository. The freshness dead-man's switch above proves
  # the backup jobs RAN; it says nothing about whether what they wrote is
  # readable. A silently-corrupt repo would have looked perfectly healthy right
  # up until a restore was attempted.
  #
  # A bare `restic check` only walks structure and metadata. --read-data-subset
  # additionally re-hashes actual pack file contents, which is the part that
  # catches bitrot on the NFS share and truncated/garbled uploads to R2.
  # 10% per nightly run rotates through the whole repo every ~10 days.
  #
  # Cost is negligible at current sizes (measured 2026-08-01: mirkwood 92M,
  # rivendell 361M, pirateship 2.4G, orthanc 3.5G) — the largest offsite repo
  # pulls ~350MB/night, and R2 charges no egress. Revisit the percentage if a
  # host's repo grows past ~20G.
  #
  # --with-cache reuses RESTIC_CACHE_DIR (set by the module) instead of building
  # a throwaway cache, which matters most for the offsite repo: without it every
  # check re-downloads the full metadata tree from R2.
  #
  # The module appends check to the SAME unit as backup and prune
  # (ExecStart = backup ++ prune ++ check), so a failed check fails
  # restic-backups-<name>.service and fires the existing OnFailure ntfy alert.
  # That alert is titled "Backup FAILED" even when it was the check that failed
  # — the journal distinguishes them, and either way the repo needs attention.
  checkOpts = [
    "--read-data-subset=10%"
    "--with-cache"
  ];

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
    # Backup run failure notifications
    # ---------------------------------------------------------------------------

    # Seed the stamps at activation (`f` creates only if absent, so an existing
    # stamp keeps its mtime). Without seeding, introducing this check would fire a
    # spurious "never ran" on every host until the first nightly run. A job that
    # genuinely never runs still goes stale and alerts within MAX_AGE_HOURS.
    systemd.tmpfiles.rules =
      [ "d ${stampDir} 0755 root root -" ]
      ++ map (u: "f ${stampDir}/${u} 0644 root root -") trackedUnits;

    systemd.services.restic-backups-local = {
      unitConfig.OnFailure = "restic-local-notify-failure.service";
      serviceConfig.ExecStopPost = [ "+${stampOnSuccess "restic-backups-local"}" ];
    };

    systemd.services.restic-backups-offsite = {
      unitConfig.OnFailure = "restic-offsite-notify-failure.service";
      serviceConfig.ExecStopPost = [ "+${stampOnSuccess "restic-backups-offsite"}" ];
    };

    systemd.services.homelab-upgrade-check = {
      serviceConfig.ExecStopPost = [ "+${stampOnSuccess "homelab-upgrade-check"}" ];
    };

    systemd.services.restic-local-notify-failure = notifyService {
      name        = "restic-local-notify-failure";
      description = "Notify ntfy of failed local backup";
      title       = "Backup FAILED (local)";
      priority    = 4;  # high
      tags        = "rotating_light";
      body        = "${host} local backup FAILED — check journalctl -u restic-backups-local";
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
    # Freshness dead-man's switch
    #
    # Each tracked unit stamps /var/lib/homelab-freshness/<unit> from ExecStopPost,
    # guarded on $SERVICE_RESULT = success. So the stamp tracks "last successful
    # run," not merely "last attempt" — a repeatedly-failing job still goes stale.
    # Fires if a service hasn't succeeded in >36h — catches both repeated
    # failures AND timer/configuration issues that prevent the service running.
    #
    # Previously this read systemd's InactiveEnterTimestamp, which is runtime-only
    # and wiped on reboot; that made every reboot between the nightly jobs and the
    # 12:00 check emit three bogus "has never completed successfully" alarms.
    #
    # Covers backups (local + offsite) and upgrades. homelab-upgrade-check is
    # the terminal step in the upgrade chain (upgrade + post-upgrade health),
    # so its InactiveEnterTimestamp is a reliable "upgrade fully succeeded" marker.
    # ---------------------------------------------------------------------------

    systemd.services.restic-freshness-check = {
      description = "Check that backups and upgrades ran recently";
      serviceConfig.Type = "oneshot";
      script = ''
        MAX_AGE_HOURS=36

        check() {
          local unit="''${1%.service}" label="$2"
          local stamp="${stampDir}/$unit"
          local ts

          # Stamp mtime, not systemd's InactiveEnterTimestamp — the latter is
          # runtime-only and reads empty after a reboot, which produced false
          # "never ran" alarms. Missing stamp now genuinely means never ran,
          # since activation seeds one for every tracked unit.
          if [ -e "$stamp" ]; then
            ts=$(${pkgs.coreutils}/bin/stat -c %Y "$stamp" 2>/dev/null)
          fi

          if [ -z "$ts" ]; then
            ${pkgs.curl}/bin/curl -s \
              --connect-timeout 5 --max-time 30 \
              -H "Title: Never ran: $label" \
              -H "Priority: 4" \
              -H "Tags: rotating_light" \
              -d "${host} $label has never completed successfully" \
              ${ntfyUrl}
            return
          fi

          # $ts is already a unix epoch (stat -c %Y), so no date parsing needed.
          local last_epoch now_epoch age_hours
          last_epoch="$ts"
          now_epoch=$(${pkgs.coreutils}/bin/date +%s)
          age_hours=$(( (now_epoch - last_epoch) / 3600 ))

          if [ "$age_hours" -gt "$MAX_AGE_HOURS" ]; then
            ${pkgs.curl}/bin/curl -s \
              --connect-timeout 5 --max-time 30 \
              -H "Title: Stale: $label" \
              -H "Priority: 4" \
              -H "Tags: rotating_light" \
              -d "${host} $label stale: last success ''${age_hours}h ago" \
              ${ntfyUrl}
          fi
        }

        # NB: no .service suffix — the argument is now a stamp basename, not a
        # systemd unit name. check() strips a stray suffix defensively anyway.
        check restic-backups-local    "local backup"
        check restic-backups-offsite  "offsite backup"
        check homelab-upgrade-check   "upgrade"
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
        inherit checkOpts;
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
        inherit checkOpts;
      };
    };
  };
}
