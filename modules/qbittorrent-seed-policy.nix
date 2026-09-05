# modules/qbittorrent-seed-policy.nix — seed forever on private trackers,
# seed to a ratio then clean up on public ones.
#
# Policy:
#   private trackers (Redacted today)  seed forever, upload uncapped
#   everything else                    seed to 1.0, then remove torrent + content,
#                                      upload capped to leave private headroom
#
# Keyed on each torrent's own `private` flag, NOT on the tracker hostname. The
# `tracker` field reports whichever tracker in the list last answered, so one
# batch of public grabs currently reports six different hosts (open.demonii.com,
# open.stealth.si, tracker.auctor.tv, tracker.opentrackr.org,
# tracker.torrent.eu.org, tracker-udp.gbitt.in) and a given torrent moves between
# them over time. `private` is baked into the .torrent, never changes, and
# already classifies the library perfectly: 51 private (all flacsfor.me) and 40
# public. It also means a future private tracker is covered the day it is added,
# with no change here.
#
# This does NOT replace the seed criteria in Prowlarr (Redacted seedRatio 99,
# The Pirate Bay seedRatio 1), which the arrs push to qBittorrent when adding a
# torrent. Those still decide when an arr will remove its own download. This unit
# is what enforces the policy on torrents the arrs do not manage, corrects the
# ones they do (99 is "effectively forever", -1 is actually forever), and is the
# only thing implementing priority at all.
#
# Removing content is safe for video and unnecessary for music, for the same
# reason in reverse:
#   Sonarr/Radarr  copyUsingHardlinks = true  -> 94.8 of 96.7 GiB under
#                  torrents/ is the same inode as the library file. Dropping the
#                  torrents/ entry just decrements the link count.
#   Lidarr         copyUsingHardlinks = FALSE -> deliberate, and must stay that
#                  way. writeAudioTags = "newFiles" and embedCoverArt = true mean
#                  Lidarr rewrites tags on import; through a hardlink that would
#                  rewrite the seeding file and fail the torrent's hash check.
#                  The cost is a real second copy (19.8 GiB today), which is the
#                  price of seeding Redacted forever. Do not "fix" this.
#
# Race worth knowing about: a public torrent that reaches 1.0 before its arr
# imports it will have its content deleted out from under the import. The window
# is small (the arrs poll every minute; reaching 1.0 means uploading the whole
# file) and self-healing -- both arrs have autoRedownloadFailed = true, so the
# outcome is a re-grab, not a hole in the library.
#
# Not in homelab.postUpgradeCheck.services: that asserts `systemctl is-active`,
# which is false for a timer-driven oneshot between runs. It alerts via
# OnFailure, matching modules/music-sync.nix.

{ config, pkgs, lib, ... }:

let
  ntfyUrl = "http://10.0.1.9:2586/homelab";
  host = config.networking.hostName;

  spec = pkgs.writeText "qbittorrent-seed-policy.json" (builtins.toJSON {
    # gluetun publishes the WebUI to the pirateship host, so this runs outside
    # the netns like qbittorrent-port-sync does.
    url = "http://localhost:9091";
    credentialsFile = "/run/secrets/qbt_credentials";

    publicRatio = 1.0;

    # Per-torrent upload cap for public torrents, in bytes/sec. Private torrents
    # are explicitly uncapped, so this is what keeps upstream available for
    # Redacted. 2 MiB/s each: high enough that a public torrent still reaches
    # 1.0 in reasonable time (and so gets cleaned up), low enough that a handful
    # of them cannot monopolise the link.
    #
    # This is an approximation, not a guarantee -- enough public torrents in
    # parallel still add up. It is nonetheless the only working lever; see the
    # measurement in qbittorrent-seed-policy.py for why the upload queue cannot
    # be used.
    publicUploadLimitBytes = 2097152;
  });
in
{
  systemd.services.qbittorrent-seed-policy = {
    description = "Apply seeding policy (private = forever, public = ratio 1.0)";
    after = [ "podman-gluetun.service" "podman-qbittorrent.service" ];
    unitConfig.OnFailure = "qbittorrent-seed-policy-notify-failure.service";
    # Timer-driven oneshot; see modules/music-sync.nix for why activation must
    # not start it. Its only legitimate trigger is the timer.
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      # A steady-state run is a couple of API calls; 5m only matters when the
      # WebUI is wedged, and then failing is the right outcome.
      TimeoutStartSec = "5m";
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.python3}/bin/python3" "${./qbittorrent-seed-policy.py}" "${spec}"
      ];
    };
  };

  systemd.timers.qbittorrent-seed-policy = {
    description = "Periodically reconcile qBittorrent seeding policy";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5m";
      OnUnitInactiveSec = "5m";
      AccuracySec = "30s";
    };
  };

  systemd.services.qbittorrent-seed-policy-notify-failure = {
    description = "Notify ntfy of a failed qBittorrent seeding policy run";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.curl}/bin/curl -s "
        + "--connect-timeout 5 --max-time 30 --retry 3 --retry-delay 10 --retry-all-errors "
        + "-H 'Title: qBittorrent seed policy FAILED' "
        + "-H 'Priority: 4' "
        + "-H 'Tags: warning,arrow_up' "
        + "-d '${host} qBittorrent seed policy failed — private torrents may be unprotected; check journalctl -u qbittorrent-seed-policy' "
        + ntfyUrl;
    };
  };
}
