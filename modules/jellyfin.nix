# modules/jellyfin.nix — Jellyfin media server (native NixOS service)
#
# Runs on orthanc (Ryzen 9 5950X + AMD RX 550).
# VAAPI hardware transcoding: H.264 + HEVC encode/decode via radeonsi (Polaris/GFX8).
# Tone mapping (HDR→SDR): CPU fallback on Polaris (ROCm dropped GFX8).
# Mesa rusticl OpenCL may enable GPU tone mapping — test after initial deploy.
#
# Post-deploy UI config (one-time):
#   Dashboard → Playback → Transcoding → Hardware acceleration: VAAPI
#   VA-API Device: /dev/dri/renderD128  (verify: ls /dev/dri/ on orthanc)
#
# To ensure direct play on Infuse (Apple TV):
#   Jellyfin admin → Users → [user] → Remote Client Bitrate Limit: 0
#   Infuse: Streaming Quality → Original; Allow Transcoding → off
#   Note: image-based subtitles (PGS/VOBSUB) still trigger transcode when
#   displayed regardless of Infuse settings — SRT/ASS subs avoid this.
#
# Data layout (native NixOS service paths):
#   /var/lib/jellyfin/config/  — config files (system.xml, network.xml, etc.)
#   /var/lib/jellyfin/data/    — library database, plugins, metadata
#   /var/cache/jellyfin/       — image cache (auto-regenerates; safe to lose)
#
# Migration from pirateship linuxserver container — path mapping:
#   pirateship:/var/lib/jellyfin/config/config/ → orthanc:/var/lib/jellyfin/config/
#   pirateship:/var/lib/jellyfin/config/data/   → orthanc:/var/lib/jellyfin/data/
#   After rsync: chown -R jellyfin:jellyfin /var/lib/jellyfin /var/cache/jellyfin

{ pkgs, ... }:

{
  # VAAPI hardware acceleration — AMD RX 550 (Polaris/GFX8, radeonsi driver)
  # libva-mesa-driver: H.264 + HEVC HW encode/decode
  # mesa: rusticl OpenCL for experimental GPU tone mapping
  # Load the amdgpu kernel module explicitly. On a headless server there is no
  # display manager to trigger DRM driver loading, so /dev/dri/* won't exist
  # without this even though the card is present.
  boot.kernelModules = [ "amdgpu" ];

  # Polaris 12 (RX 550) requires firmware from linux-firmware (polaris12_sdma.bin
  # et al). Without this amdgpu initialises then immediately fails with -ENOENT.
  hardware.firmware = [ pkgs.linux-firmware ];

  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      # mesa includes radeonsi (VAAPI H.264/HEVC) + rusticl OpenCL
      # rusticl enables experimental GPU tone mapping on GFX8 (Polaris)
      mesa
    ];
  };

  services.jellyfin.enable = true;

  systemd.services.jellyfin.environment = {
    XDG_CACHE_HOME = "/var/cache/jellyfin";
  };

  # /dev/dri/* access for VAAPI render nodes
  users.users.jellyfin.extraGroups = [ "video" "render" ];

  # Accessible from rivendell (Caddy) and local network
  networking.firewall.allowedTCPPorts = [ 8096 ];
}
