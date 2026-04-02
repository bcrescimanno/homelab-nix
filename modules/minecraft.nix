# modules/minecraft.nix — Minecraft Java Edition server
#
# Runs the latest stable Minecraft server via the NixOS native module.
# Resource limits via systemd prevent Minecraft from starving concurrent
# workloads (remote builds) on orthanc.
#
# After deployment, the server is reachable at orthanc.home.theshire.io:25565
# from the local network. No external exposure by default.
#
# To change the Minecraft version, override `services.minecraft-server.package`:
#   services.minecraft-server.package = pkgs.minecraftServers.vanilla-1_21;
# Available packages: `nix search nixpkgs minecraftServers`
#
# World data and config live at /var/lib/minecraft (declared as a backup path
# in hosts/orthanc.nix).

{ config, pkgs, lib, ... }:

{
  # Minecraft server has an unfree license; allow it explicitly rather than
  # setting a blanket allowUnfree = true.
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "minecraft-server" ];

  services.minecraft-server = {
    enable = true;
    eula = true; # Accept Minecraft EULA — required to run the server

    # JVM options: 6GB heap with Aikar's recommended G1GC flags for
    # low-latency server performance. Leaves ~26GB free for other workloads.
    jvmOpts = lib.concatStringsSep " " [
      "-Xmx6G" "-Xms2G"
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

    serverProperties = {
      server-port = 25565;
      gamemode = "survival";
      difficulty = "normal";
      max-players = 10;
      view-distance = 10;
      simulation-distance = 10;
      online-mode = true;
      motd = "orthanc — the tower of Isengard";
      white-list = false;
    };
  };

  # Resource isolation: cap Minecraft at 4 cores and 8GB so a busy world
  # cannot starve concurrent remote build jobs on the 5950X.
  systemd.services.minecraft-server.serviceConfig = {
    CPUQuota = "400%"; # 4 of 16 logical cores (systemd: percent of one core)
    MemoryMax = "8G";
    Restart = "on-failure";
  };

  networking.firewall = {
    allowedTCPPorts = [ 25565 ];
    allowedUDPPorts = [ 25565 ];
  };
}
