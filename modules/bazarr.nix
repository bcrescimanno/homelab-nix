# modules/bazarr.nix — Bazarr subtitle manager
#
# Companion to Radarr/Sonarr: monitors the media library for missing subtitles
# and downloads them from configured providers (OpenSubtitles.com, etc.).
#
# Runs as the `brian` user (uid 1000) to match the PUID=1000 used by the arr
# containers, ensuring it can read/write subtitle files on the erebor NFS mount.
#
# One-time web UI setup required after first deploy:
#   1. Open subtitles.theshire.io → Settings → Sonarr
#      - Host: localhost, Port: 8989, API key from Sonarr UI
#   2. Settings → Radarr
#      - Host: localhost, Port: 7878, API key from Radarr UI
#   3. Settings → Providers → add OpenSubtitles.com (free account required)
#   4. Settings → Languages → set profile to English

{ ... }:

{
  services.bazarr = {
    enable = true;
    # Run as brian (uid 1000) to match arr container PUID — required for NFS write access
    user = "brian";
    group = "users";
    listenPort = 6767;
    openFirewall = true;
  };
}
