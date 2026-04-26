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
    };
  };

  networking.firewall.allowedTCPPorts = [ 4533 ];

  homelab.postUpgradeCheck.services = [ "navidrome" ];
}
