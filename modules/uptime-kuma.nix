# modules/uptime-kuma.nix — Uptime Kuma service monitor
#
# Web-based uptime monitoring with alerting. Polls configured services
# on a schedule and sends alerts (via ntfy, email, etc.) when they go down.
#
# Port 3001 is LAN-accessible for direct access; also proxied via NPM
# at https://status.theshire.io.
#
# All monitor configuration is done through the web UI — no config files.
# Data persists in /var/lib/uptime-kuma.

{ config, pkgs, lib, ... }:

{
  virtualisation.oci-containers.containers.uptime-kuma = {
    image = "docker.io/louislam/uptime-kuma:1@sha256:3d632903e6af34139a37f18055c4f1bfd9b7205ae1138f1e5e8940ddc1d176f9";
    autoStart = true;
    volumes = [
      "/var/lib/uptime-kuma:/app/data"
    ];
    environment = {
      TZ = "America/Los_Angeles";
    };
    ports = [ "3001:3001" ];
  };

  networking.firewall.allowedTCPPorts = [ 3001 ];

  systemd.tmpfiles.rules = [
    "d /var/lib/uptime-kuma 0755 root root -"
  ];
}
