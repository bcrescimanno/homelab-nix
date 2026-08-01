# modules/jellyfin-notify.nix — push library updates to Jellyfin on import
#
# Jellyfin runs natively on orthanc; its media arrives over NFS from erebor and
# is written by the arr containers on pirateship. Both libraries have
# EnableRealtimeMonitor=true, but inotify does not deliver events for changes
# made by a different NFS client, so the watcher never fires. The library
# therefore only updated on the scheduled scan, and in between it kept serving
# paths for files that upgrades had already replaced — 42 such stale entries
# were present when this was written (mostly Downton Abbey quality upgrades).
#
# Radarr, Sonarr and Bazarr all support pushing a targeted library update. None
# of them had any notification configured. This module declares that wiring and
# reconciles it over each app's API, the same pattern as lidarr-formats.nix.
#
# Two things make this less obvious than it looks:
#
# 1. PATH TRANSLATION. Radarr/Sonarr run inside gluetun's netns with
#    /var/lib/media bind-mounted at /media, so they know a file as
#    /media/movies/X while Jellyfin knows it as /var/lib/media/movies/X. The
#    MediaBrowser notification sends the path to Jellyfin for a targeted
#    refresh, so without mapFrom/mapTo Jellyfin cannot match it to a library
#    item and the refresh silently does nothing. This is the same class of bug
#    that left Bazarr's path mappings broken and silent for four months.
#
# 2. LAN EGRESS. The arr containers share gluetun's network namespace, where
#    policy rule 101 sends everything without the WireGuard fwmark into tun0 and
#    the iptables OUTPUT policy is DROP. Reaching orthanc therefore requires the
#    FIREWALL_OUTBOUND_SUBNETS exception added in arr-stack.nix. It is scoped to
#    orthanc's /32 rather than the whole LAN so that blocky (10.0.1.8/.9) and
#    the UDM Pro stay unreachable from the netns — that keeps the only plausible
#    tunnel-bypass vector, a DNS resolver misconfiguration, closed.
#
# Bazarr is unaffected by (2): it runs natively on the host, not in the netns.
#
# Library IDs are discovered from Jellyfin at runtime rather than pinned here,
# so recreating a library does not silently break the mapping.

{ config, pkgs, lib, ... }:

let
  jellyfinHost = "10.0.1.10";   # orthanc

  spec = pkgs.writeText "jellyfin-notify.json" (builtins.toJSON {
    jellyfin = { host = jellyfinHost; port = 8096; useSsl = false; };

    arr = [
      {
        app = "radarr";
        port = 7878;
        keyFile = config.sops.secrets.recyclarr_radarr_api_key.path;
        notificationName = "Jellyfin";
        mapFrom = "/media";
        mapTo = "/var/lib/media";
        # onGrab is deliberately absent — nothing exists to refresh yet.
        triggers = [
          "onDownload" "onUpgrade" "onRename"
          "onMovieDelete" "onMovieFileDelete" "onMovieFileDeleteForUpgrade"
        ];
      }
      {
        app = "sonarr";
        port = 8989;
        keyFile = config.sops.secrets.recyclarr_sonarr_api_key.path;
        notificationName = "Jellyfin";
        mapFrom = "/media";
        mapTo = "/var/lib/media";
        # onImportComplete is omitted: onDownload already covers imports, and
        # enabling both just issues a duplicate refresh per batch.
        triggers = [
          "onDownload" "onUpgrade" "onRename"
          "onSeriesDelete" "onEpisodeFileDelete" "onEpisodeFileDeleteForUpgrade"
        ];
      }
    ];

    bazarr = {
      port = 6767;
      configPath = "/var/lib/bazarr/config/config.yaml";
      refreshMethod = "immediate";
    };
  });
in
{
  systemd.services.jellyfin-notify-sync = {
    description = "Sync Jellyfin library-update notifications into Radarr/Sonarr/Bazarr";
    after = [
      "podman-gluetun.service" "podman-radarr.service" "podman-sonarr.service"
      "bazarr.service" "network-online.target"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Radarr/Sonarr validate the connection when saving a notification, so a
      # failure here is a real signal that the push does not work. Retry rather
      # than latch: after a gluetun restart the netns takes a while to settle.
      Restart = "on-failure";
      RestartSec = "60s";
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.python3}/bin/python3"
        "${./jellyfin-notify-sync.py}"
        "${spec}"
        config.sops.secrets.jellyfin_api_key.path
      ];
    };
  };

  homelab.postUpgradeCheck.services = [ "jellyfin-notify-sync" ];
}
