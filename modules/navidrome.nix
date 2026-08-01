# modules/navidrome.nix — Navidrome music streaming server
#
# OpenSubsonic-compatible music server for remote/mobile access.
# Music library is read from the erebor NFS mount at /var/lib/media/music.
#
# Internal access: stream.theshire.io → Caddy (rivendell) → pirateship:4533
# External access: stream.theshire.io → Cloudflare Tunnel (orthanc) → pirateship:4533
#
# After first deploy, create an admin account at http://pirateship:4533 —
# Navidrome locks new registrations after the first user is created.
# iOS client: Amperfy (App Store, free) — configure with stream.theshire.io.
#
# Port: 4533

{ config, pkgs, lib, ... }:

{
  services.navidrome = {
    enable = true;
    settings = {
      MusicFolder = "/var/lib/media/music";
      Address     = "0.0.0.0";
      Port        = 4533;
      LogLevel    = "info";
      # Navidrome's inotify watcher DOES work here, contrary to what an earlier
      # version of this comment claimed: inotify is delivered for writes made
      # through this mount by this host, and both Navidrome and the arr
      # containers are on pirateship. The journal has ~92 "Watcher: Triggering
      # scan for changed folders" events going back to March.
      #
      # (The earlier claim came from grepping the journal for "Starting scan",
      # which only matches *scheduled* scans — watcher-driven scans log an
      # entirely different string. Do not re-derive that conclusion from a
      # "Starting scan" grep.)
      #
      # What the watcher genuinely cannot see is a write made on another NFS
      # client — i.e. an album copied straight onto erebor over SMB, which is
      # exactly the manual CD-rip path. Periodic scanning is the safety net for
      # that case, not the primary mechanism.
      #
      # 5m rather than 1h because a quick scan is itself just a directory-mtime
      # walk (0.4–2.3s, 17.7s when it finds something), so bounding the
      # NAS-direct blind spot to five minutes is close to free. Navidrome is
      # deliberately not pushed to from modules/music-sync.nix: 0.63.2 does not
      # advertise the apiKeyAuthentication OpenSubsonic extension, so triggering
      # startScan would mean keeping a user's password in sops.
      "Scanner.Schedule" = "5m";
    };
  };

  networking.firewall.allowedTCPPorts = [ 4533 ];

  homelab.postUpgradeCheck.services = [ "navidrome" ];
}
