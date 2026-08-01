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
      # The library is on the erebor NFS mount, so Navidrome's inotify watcher is
      # inert — measured over 24h, scans only ever landed on the hour, even
      # though Lidarr imported four times that day. Periodic scanning (disabled
      # by default in 0.62) is the only thing that actually picks changes up.
      #
      # 5m, not 1h: a quick scan is itself just a directory-mtime walk and takes
      # 0.4–2.3s (17.7s when it finds something), so this is close to free and
      # keeps Navidrome roughly in step with modules/music-sync.nix, which drives
      # Lidarr and Music Assistant on a 2-minute tick. Navidrome is deliberately
      # not pushed to from there: 0.63.2 does not advertise the
      # apiKeyAuthentication OpenSubsonic extension, so triggering startScan
      # would mean keeping a user's password in sops to save ~3 minutes.
      "Scanner.Schedule" = "5m";
    };
  };

  networking.firewall.allowedTCPPorts = [ 4533 ];

  homelab.postUpgradeCheck.services = [ "navidrome" ];
}
