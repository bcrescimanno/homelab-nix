# modules/navidrome.nix — Navidrome music streaming server
#
# Subsonic-compatible music server for the FLAC library on erebor.
# Proxied via Caddy at listen.theshire.io.
#
# On first access, navigate to listen.theshire.io to create the admin account.
# The Subsonic API (for WiiM devices, Symfonium, etc.) is available at
# listen.theshire.io/rest — configure clients with this base URL.
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
}
