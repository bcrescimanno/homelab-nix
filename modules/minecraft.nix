# modules/minecraft.nix — Modded Minecraft server (Prominence II RPG)
#
# Uses the itzg/minecraft-server container image which handles Forge installation
# and CurseForge modpack downloads automatically via the AUTO_CURSEFORGE type.
#
# Requires a CurseForge API key in the `minecraft_env` sops secret:
#   CF_API_KEY=<your key from console.curseforge.com>
#
# The pack is identified by CF_SLUG. To find it: open the modpack page on
# CurseForge and copy the slug from the URL (e.g. prominence-ii-rpg).
# Pin a specific file with CF_FILE_ID (numeric, from the Files tab URL) to
# prevent the server auto-updating mid-session; omit to always use latest.
#
# World data and server files live at /var/lib/minecraft (declared as a backup
# path in hosts/orthanc.nix). The container mounts this as /data.
#
# Server is reachable at orthanc.home.theshire.io:25565 (LAN only).

{ config, pkgs, lib, ... }:

{
  # Ensure the data directory exists before the container starts.
  systemd.tmpfiles.rules = [
    "d /var/lib/minecraft 0755 root root -"
  ];

  sops.secrets.minecraft_env = {};

  virtualisation.oci-containers.containers.minecraft = {
    image = "itzg/minecraft-server:java21@sha256:07798b14dd734fcca70919dabdf211aca38fe748cd040e05cc98da56c10c10e2";
    autoStart = true;

    environment = {
      EULA = "TRUE";
      TYPE = "AUTO_CURSEFORGE";

      # Prominence II RPG 2 — set CF_SLUG to the CurseForge modpack slug.
      # Find it at: https://www.curseforge.com/minecraft/modpacks/<slug>
      CF_SLUG = "prominence-2-hasturian-era";

      # Pin to a specific modpack file to prevent auto-updates mid-session.
      # Get the numeric ID from the Files tab URL on CurseForge, then uncomment:
      # CF_FILE_ID = "1234567";

      # JVM options: Aikar's G1GC flags, 6GB heap.
      JVM_OPTS = lib.concatStringsSep " " [
        "-XX:+UseG1GC"
        "-XX:+ParallelRefProcEnabled"
        "-XX:MaxGCPauseMillis=200"
        "-XX:+UnlockExperimentalVMOptions"
        "-XX:+DisableExplicitGC"
        "-XX:+AlwaysPreTouch"
        "-XX:G1NewSizePercent=30"
        "-XX:G1MaxNewSizePercent=40"
        "-XX:G1HeapRegionSize=8M"
        "-XX:G1ReservePercent=20"
        "-XX:G1HeapWastePercent=5"
        "-XX:G1MixedGCCountTarget=4"
        "-XX:InitiatingHeapOccupancyPercent=15"
        "-XX:G1MixedGCLiveThresholdPercent=90"
        "-XX:G1RSetUpdatingPauseTimePercent=5"
        "-XX:SurvivorRatio=32"
        "-XX:+PerfDisableSharedMem"
        "-XX:MaxTenuringThreshold=1"
      ];
      MEMORY = "6G";

      # Server properties
      GAMEMODE = "survival";
      DIFFICULTY = "normal";
      MAX_PLAYERS = "10";
      VIEW_DISTANCE = "10";
      SIMULATION_DISTANCE = "10";
      ONLINE_MODE = "TRUE";
      MOTD = "orthanc — the tower of Isengard";
      ALLOW_FLIGHT = "TRUE"; # Many modpacks require this (jetpacks, mounts, etc.)
    };

    # CF_API_KEY is loaded from the sops secret.
    environmentFiles = [ config.sops.secrets.minecraft_env.path ];

    volumes = [ "/var/lib/minecraft:/data" ];
    ports = [ "25565:25565" ];

    # Disable the built-in healthcheck — Minecraft takes several minutes to
    # start (modpack download + Forge install), so the healthcheck fires during
    # activation and causes a spurious rollback.
    extraOptions = [ "--no-healthcheck" ];
  };

  # Resource isolation: cap Minecraft at 4 cores and 8GB so a busy world
  # cannot starve concurrent remote build jobs on the 5950X.
  systemd.services.podman-minecraft.serviceConfig = {
    CPUQuota = "400%";
    MemoryMax = "8G";
    Restart = lib.mkForce "on-failure";
    RestartSec = "30s";
  };

  networking.firewall = {
    allowedTCPPorts = [ 25565 ];
    allowedUDPPorts = [ 25565 ];
  };
}
