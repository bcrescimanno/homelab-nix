# modules/dns.nix — Technitium DNS Server
#
# Technitium is a full-featured DNS server with a web UI. It replaces the
# previous Pi-hole + Unbound + Redis + Nebula-Sync stack with a single
# container that handles recursive resolution and zone sync natively.
#
# This module runs on both mirkwood (primary) and rivendell (secondary).
# Primary/secondary sync is configured in the Technitium web UI after
# both instances are up — it is not declared here.
#
# Secrets: the host's sops config must declare `technitium_env`, a file
# containing at minimum:
#   DNS_SERVER_ADMIN_PASSWORD=<password>

{ config, pkgs, lib, ... }:

{
  virtualisation.oci-containers.containers.technitium = {
    image = "docker.io/technitium/dns-server:latest";
    autoStart = true;

    volumes = [
      "/var/lib/technitium/config:/etc/dns"
    ];

    environment = {
      # Use the hostname as this server's DNS identity (shows in Technitium UI).
      DNS_SERVER_DOMAIN = config.networking.hostName;
      # Recursive resolution for private network clients only — safe default.
      DNS_SERVER_RECURSION = "AllowOnlyForPrivateNetworks";
      DNS_SERVER_PREFER_IPv6 = "false";
      DNS_SERVER_LOG_USING_LOCAL_TIME = "true";
    };

    # Admin password is supplied via sops-managed env file.
    extraOptions = [
      "--env-file=/run/secrets/technitium_env"
    ];

    ports = [
      "53:53/tcp"
      "53:53/udp"
      "5380:5380/tcp"
    ];
  };

  networking.firewall = {
    allowedTCPPorts = [ 53 5380 ];
    allowedUDPPorts = [ 53 ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/technitium/config 0755 root root -"
  ];
}
