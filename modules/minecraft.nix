# modules/minecraft.nix — Modded Minecraft servers
#
# Uses the itzg/minecraft-server container image which handles Forge installation
# and CurseForge modpack downloads automatically via the AUTO_CURSEFORGE type.
#
# Requires a CurseForge API key in the `minecraft_env` sops secret (shared by all
# server instances):
#   CF_API_KEY=<your key from console.curseforge.com>
#
# Each entry in `servers` below becomes its own itzg/minecraft-server container
# with an independent data directory, port, and resource caps. To add a pack:
# open its CurseForge page, copy the slug from the URL into `cfSlug`, pick an
# unused port, and add it to the backup paths in hosts/orthanc.nix.
#
# Pin a specific file with `cfFileId` (numeric, from the Files tab URL) to
# prevent the server auto-updating mid-session; leave null to always use latest.
#
# Servers are reachable at orthanc.home.theshire.io:<port> (LAN only).
#   - prominence      → 25565 (Prominence II RPG — Hasturian Era)
#   - abyssal-ascent  → 25566 (Abyssal Ascent)

{ config, pkgs, lib, ... }:

let
  # Aikar's G1GC flags, shared by every instance.
  aikarFlags = lib.concatStringsSep " " [
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

  image = "itzg/minecraft-server:java21@sha256:a1e038496768c51e271e888019496c8c51dc7687d6d171d0a0b05ee59df0b8da";

  # Per-server definitions. `memory` is the JVM heap; `memoryMax` is the cgroup
  # hard cap (heap + off-heap + Forge overhead). Each is pinned to 4 cores so a
  # busy world cannot starve the other server or concurrent remote build jobs on
  # the 5950X.
  servers = {
    prominence = {
      cfSlug = "prominence-2-hasturian-era";
      cfFileId = null;
      port = 25565;
      # Keep the existing data path so the live world is not orphaned.
      dataDir = "/var/lib/minecraft";
      memory = "6G";
      memoryMax = "8G";
      motd = "orthanc — the tower of Isengard";
    };
    abyssal-ascent = {
      cfSlug = "abyssal-ascent";
      cfFileId = null;
      port = 25566;
      dataDir = "/var/lib/minecraft-abyssal-ascent";
      # Pack author recommends ~4G; 8G+ is documented to cause instability.
      memory = "4G";
      memoryMax = "6G";
      motd = "orthanc — climb from the abyss";
    };
  };

  mkContainer = name: srv: {
    inherit image;
    autoStart = true;

    environment = {
      EULA = "TRUE";
      TYPE = "AUTO_CURSEFORGE";
      CF_SLUG = srv.cfSlug;
      JVM_OPTS = aikarFlags;
      MEMORY = srv.memory;

      # Server properties
      GAMEMODE = "survival";
      DIFFICULTY = "normal";
      MAX_PLAYERS = "10";
      VIEW_DISTANCE = "10";
      SIMULATION_DISTANCE = "10";
      ONLINE_MODE = "TRUE";
      MOTD = srv.motd;
      ALLOW_FLIGHT = "TRUE"; # Many modpacks require this (jetpacks, mounts, etc.)
    } // lib.optionalAttrs (srv.cfFileId != null) {
      # Pin to a specific modpack file to prevent auto-updates mid-session.
      CF_FILE_ID = srv.cfFileId;
    };

    # CF_API_KEY is loaded from the sops secret (shared across instances).
    environmentFiles = [ config.sops.secrets.minecraft_env.path ];

    volumes = [ "${srv.dataDir}:/data" ];
    # Map each server's host port onto the container's standard 25565.
    ports = [ "${toString srv.port}:25565" ];

    # Disable the built-in healthcheck — Minecraft takes several minutes to
    # start (modpack download + Forge install), so the healthcheck fires during
    # activation and causes a spurious rollback.
    extraOptions = [ "--no-healthcheck" ];
  };
in
{
  # Ensure each server's data directory exists before its container starts.
  systemd.tmpfiles.rules =
    lib.mapAttrsToList (name: srv: "d ${srv.dataDir} 0755 root root -") servers;

  sops.secrets.minecraft_env = {};

  virtualisation.oci-containers.containers =
    lib.mapAttrs' (name: srv: lib.nameValuePair "minecraft-${name}" (mkContainer name srv)) servers;

  # Resource isolation per instance.
  systemd.services =
    lib.mapAttrs' (name: srv: lib.nameValuePair "podman-minecraft-${name}" {
      serviceConfig = {
        CPUQuota = "400%";
        MemoryMax = srv.memoryMax;
        Restart = lib.mkForce "on-failure";
        RestartSec = "30s";
      };
    }) servers;

  networking.firewall = {
    allowedTCPPorts = lib.mapAttrsToList (name: srv: srv.port) servers;
    allowedUDPPorts = lib.mapAttrsToList (name: srv: srv.port) servers;
  };
}
