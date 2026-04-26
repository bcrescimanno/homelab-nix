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

  # node_exporter exposes host metrics for Prometheus on mirkwood.
  # Textfile collector reads .prom files from /var/lib/prometheus-textfiles —
  # the attic post-build hook writes push success/failure counters there.
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    enabledCollectors = [ "textfile" ];
    extraFlags = [ "--collector.textfile.directory=/var/lib/prometheus-textfiles" ];
    openFirewall = true;
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/prometheus-textfiles 0755 root root -"
  ];
}
