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

  # systemd exporter — per-unit state, so a failed timer or oneshot becomes a
  # metric instead of something you only find by running systemctl by hand.
  # This is what backs the UnitFailed alert rule in modules/grafana.nix.
  services.prometheus.exporters.systemd = {
    enable = true;
    port = 9558;
    openFirewall = true;
  };

  # smartctl exporter — disk health. Nothing was watching this before: an NVMe
  # working its way through its spare blocks was completely invisible on every
  # host.
  #
  # Only nvme0n1 is listed. Explicitly enumerating rather than letting the
  # exporter auto-scan keeps zram0 (and pirateship's mmcblk0 SD card) out of it
  # — neither exposes SMART, and a device that cannot answer produces scrape
  # errors rather than useful data. Verified 2026-08-01: every host has exactly
  # one NVMe, and those are the only SMART-capable devices present.
  services.prometheus.exporters.smartctl = {
    enable = true;
    port = 9633;
    devices = [ "/dev/nvme0n1" ];
    openFirewall = true;
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/prometheus-textfiles 0755 root root -"
  ];

  homelab.postUpgradeCheck.services = [ "glances" ];
}
