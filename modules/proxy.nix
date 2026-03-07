# modules/proxy.nix — Nginx Proxy Manager
#
# Provides a web UI for managing reverse proxy rules, SSL certificates,
# and access lists. Runs on rivendell and acts as the public-facing
# entry point for all homelab services.
#
# Ports:
#   80/443 — HTTP/HTTPS proxy traffic (forwarded to backend services)
#   81     — NPM admin UI (initial credentials set on first login)
#
# No secrets needed: admin account is created through the web UI on
# first boot (default login: admin@example.com / changeme).

{ config, pkgs, lib, ... }:

{
  virtualisation.oci-containers.containers.npm = {
    image = "docker.io/jc21/nginx-proxy-manager:latest@sha256:2aa69b382a384b676c0d4f1d6f2eac40ecd478fcf7af1cfb3f9f1d3cd0c81e12";
    autoStart = true;
    volumes = [
      "/var/lib/npm/data:/data"
      "/var/lib/npm/letsencrypt:/etc/letsencrypt"
    ];
    ports = [
      "80:80/tcp"
      "443:443/tcp"
      "81:81/tcp"
    ];
  };

  networking.firewall.allowedTCPPorts = [ 80 443 81 ];

  systemd.tmpfiles.rules = [
    "d /var/lib/npm/data 0755 root root -"
    "d /var/lib/npm/letsencrypt 0755 root root -"
  ];
}
