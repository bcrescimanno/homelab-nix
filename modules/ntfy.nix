# modules/ntfy.nix — ntfy push notification server
#
# Self-hosted pub/sub notification service. Clients (HA, NUT scripts,
# Uptime Kuma, etc.) publish to topics; the ntfy iOS/Android app
# subscribes and receives push notifications.
#
# Port 2586 is exposed on the LAN so other homelab hosts (pirateship,
# mirkwood) can publish notifications without going through NPM.
# The web UI is also proxied via NPM at https://ntfy.theshire.io.
#
# No authentication configured by default — add ntfy auth via the
# server.yml config file if the instance is ever exposed publicly.

{ config, pkgs, lib, ... }:

{
  virtualisation.oci-containers.containers.ntfy = {
    image = "docker.io/binwiederhier/ntfy:latest@sha256:b32b4221a64ec2e7c000f0782b2feef24022e1a09a24e531640f4cbba6cfa1e6";
    autoStart = true;
    cmd = [ "serve" ];
    volumes = [
      "/var/lib/ntfy/cache:/var/cache/ntfy"
      "/var/lib/ntfy/config:/etc/ntfy"
    ];
    environment = {
      TZ = "America/Los_Angeles";
      NTFY_BASE_URL = "https://ntfy.theshire.io";
      NTFY_CACHE_FILE = "/var/cache/ntfy/cache.db";
      NTFY_BEHIND_PROXY = "true";
      # Required for iOS push delivery: ntfy.sh acts as APNs relay for
      # self-hosted instances. Without this, iOS devices never receive
      # notifications when the app is in the background.
      NTFY_UPSTREAM_BASE_URL = "https://ntfy.sh";
    };
    ports = [ "2586:80" ];
  };

  # Expose on LAN so pirateship/mirkwood can publish notifications.
  # Web UI is proxied via NPM at https://ntfy.theshire.io.
  networking.firewall.allowedTCPPorts = [ 2586 ];

  systemd.tmpfiles.rules = [
    "d /var/lib/ntfy/cache 0755 root root -"
    "d /var/lib/ntfy/config 0755 root root -"
  ];

  homelab.postUpgradeCheck.services = [ "podman-ntfy" ];
}
