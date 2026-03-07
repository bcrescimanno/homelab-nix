# modules/monitoring.nix — Glances system monitoring
#
# Glances runs as a native systemd service (not a container) so it has
# direct access to host metrics via /proc and /sys without needing
# --privileged. The nixpkgs module handles the systemd unit, hardening,
# and firewall rule.
#
# Web UI accessible at http://<host>:61208

{ config, pkgs, lib, ... }:

{
  services.glances = {
    enable = true;
    openFirewall = true;
  };
}
