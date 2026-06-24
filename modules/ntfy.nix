# modules/ntfy.nix — ntfy push notification server (native NixOS service)
#
# Self-hosted pub/sub notification service. Clients (HA, NUT scripts,
# backup/upgrade hooks, Gatus, etc.) publish to topics; the ntfy iOS/Android
# app subscribes and receives push notifications.
#
# Port 2586 is exposed on the LAN so other homelab hosts (pirateship,
# mirkwood) and HA can publish notifications directly. The web UI is also
# proxied via Caddy at https://ntfy.theshire.io.
#
# No authentication configured by default — add ntfy auth via the
# `settings` attrset if the instance is ever exposed publicly.

{ config, pkgs, lib, ... }:

{
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://ntfy.theshire.io";
      # Default listen-http is mkDefault 127.0.0.1:2586; override to expose on
      # the LAN so other hosts can publish without going through Caddy.
      listen-http = ":2586";
      behind-proxy = true;
      # Required for iOS push delivery: ntfy.sh acts as APNs relay for
      # self-hosted instances. Without this, iOS devices never receive
      # notifications when the app is in the background.
      upstream-base-url = "https://ntfy.sh";
    };
  };

  # Expose on LAN so pirateship/mirkwood/HA can publish notifications.
  # Web UI is proxied via Caddy at https://ntfy.theshire.io.
  networking.firewall.allowedTCPPorts = [ 2586 ];

  homelab.postUpgradeCheck.services = [ "ntfy-sh" ];
}
