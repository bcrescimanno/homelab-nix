# modules/music-sync.nix — keep Lidarr, Navidrome and Music Assistant in step
#
# Four services read the same erebor NFS share at /var/lib/media/music, and every
# filesystem watcher on it is inert. inotify does not deliver events for writes
# made by a different NFS client, and the writers are always elsewhere: an arr
# container on pirateship, or a CD rip copied straight onto the NAS. Same root
# cause already documented for Jellyfin in modules/jellyfin-notify.nix and for
# Bazarr's realtime monitor.
#
# So each service fell back to its own schedule, and the real numbers were much
# worse than the configured ones looked:
#
#   Navidrome         Scanner.Schedule "1h"        -- honoured; watcher never fired.
#                     24h of journal showed scans only on the hour, despite Lidarr
#                     importing at 09:11, 10:06, 10:44 and 13:40 that day.
#   Music Assistant   provider_sync_interval_* 30  -- DEAD CONFIG. Nothing in 2.9.9
#                     reads those keys; the real schedule is a hardcoded
#                     TaskSchedule.hourly(every=12) in models/music_provider.py.
#                     The library synced twice a day.
#   Lidarr            RescanFolders daily          -- and ~6 min per run, since it
#                     walks all 99 artist folders.
#
# music-sync.timer replaces that with detection cheap enough to run every two
# minutes: stat the ~278 directories (0.09s warm, 1.28s cold) and compare mtimes.
# A change must persist for one full interval before anything is triggered, so a
# half-copied album or an in-flight import is never scanned mid-write. When the
# tree does settle, only the artists that actually changed are refreshed.
#
# Placement matters: this runs on the pirateship HOST, not inside gluetun's
# network namespace. It reaches Lidarr on 127.0.0.1:8686 (gluetun publishes it to
# the host) and Music Assistant on rivendell directly. Driving it from a Lidarr
# custom script instead would need rivendell added to FIREWALL_OUTBOUND_SUBNETS,
# and rivendell is a blocky DNS host — see the gluetun-lan-exception rationale in
# arr-stack.nix for why that list stays at orthanc's /32.
#
# Navidrome is not pushed to. Its quick scan is already an mtime walk that
# finishes in under a second, so it only needed a shorter schedule (see
# modules/navidrome.nix). 0.63.2 does not advertise the apiKeyAuthentication
# OpenSubsonic extension, so a push would mean storing a user's password in sops
# to save two or three minutes of latency.
#
# music-library-audit.timer is the daily counterpart: it repairs Lidarr artists
# whose folder has drifted from the disk and nags about folders that need a
# manual Library Import. See music-library-audit.py for why that class of bug is
# invisible without it.
#
# Neither unit belongs in homelab.postUpgradeCheck.services: that check asserts
# `systemctl is-active` == active, which is false for a timer-driven oneshot
# between runs. They alert through OnFailure instead.

{ config, pkgs, lib, ... }:

let
  ntfyUrl  = "http://10.0.1.9:2586/homelab";
  host     = config.networking.hostName;
  stateDir = "/var/lib/music-sync";

  musicRoot = "/var/lib/media/music";

  # Lidarr's view of the same share: the container bind-mounts /var/lib/media at
  # /media, so its artist paths read /media/music/<Artist>.
  lidarr = {
    port = 8686;
    lidarrRoot = "/media/music";
    # Read from Lidarr's own config at runtime rather than sops: Lidarr generates
    # it, it changes if the config volume is reset, and it is already on disk.
    # Same reasoning as modules/lidarr-formats.nix.
    configPath = "/var/lib/lidarr/config/config.xml";
  };

  syncSpec = pkgs.writeText "music-sync.json" (builtins.toJSON {
    inherit musicRoot lidarr;
    statePath = "${stateDir}/state.json";
    musicAssistant = {
      url = "http://10.0.1.9:8095";          # rivendell
      tokenFile = config.sops.secrets.ma_token.path;
    };
  });

  auditSpec = pkgs.writeText "music-library-audit.json" (builtins.toJSON {
    inherit musicRoot lidarr host ntfyUrl;
  });
in
{
  # Long-lived Music Assistant API token for the `brian` user. music/sync only
  # requires an authenticated caller, not an admin one.
  sops.secrets.ma_token = {};

  systemd.tmpfiles.rules = [ "d ${stateDir} 0755 root root -" ];

  # --------------------------------------------------------------- change watch
  systemd.services.music-sync = {
    description = "Refresh music libraries when the shared music tree changes";
    after = [ "podman-lidarr.service" "network-online.target" "var-lib-media.mount" ];
    wants = [ "network-online.target" ];
    unitConfig.OnFailure = "music-sync-notify-failure.service";
    serviceConfig = {
      Type = "oneshot";
      # Well above the measured 1.3s cold walk, but low enough that a hung NFS
      # mount fails the run instead of pinning the timer forever.
      TimeoutStartSec = "5m";
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.python3}/bin/python3" "${./music-sync.py}" "${syncSpec}"
      ];
    };
  };

  systemd.timers.music-sync = {
    description = "Poll the music tree for changes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3m";
      OnUnitInactiveSec = "2m";
      AccuracySec = "15s";
    };
  };

  # ---------------------------------------------------------------- daily audit
  systemd.services.music-library-audit = {
    description = "Repair Lidarr artist folders and report unimported music";
    after = [ "podman-lidarr.service" "network-online.target" "var-lib-media.mount" ];
    wants = [ "network-online.target" ];
    unitConfig.OnFailure = "music-sync-notify-failure.service";
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "15m";
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.python3}/bin/python3" "${./music-library-audit.py}" "${auditSpec}"
      ];
    };
  };

  systemd.timers.music-library-audit = {
    description = "Daily Lidarr music library audit";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "09:30";
      RandomizedDelaySec = "20m";
      Persistent = true;
    };
  };

  systemd.services.music-sync-notify-failure = {
    description = "Notify ntfy of a failed music library sync";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.curl}/bin/curl -s "
        + "--connect-timeout 5 --max-time 30 --retry 3 --retry-delay 10 --retry-all-errors "
        + "-H 'Title: Music library sync FAILED' "
        + "-H 'Priority: 3' "
        + "-H 'Tags: musical_note' "
        + "-d '${host} music library sync failed — check journalctl -u music-sync -u music-library-audit' "
        + ntfyUrl;
    };
  };
}
