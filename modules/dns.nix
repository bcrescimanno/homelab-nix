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
    image = "docker.io/technitium/dns-server:latest@sha256:94f2b90d63f03181421152157a8099ea2752b13fa30b6c96833859be8e93dfa9";
    autoStart = true;

    volumes = [
      "/var/lib/technitium/config:/etc/dns"
    ];

    environment = {
      # Use the hostname as this server's DNS identity (shows in Technitium UI).
      DNS_SERVER_DOMAIN = config.networking.hostName;
      # Recursive resolution for private network clients only — no upstream
      # forwarder, queries go directly to root servers for maximum privacy.
      DNS_SERVER_RECURSION = "AllowOnlyForPrivateNetworks";
      # Validate DNSSEC signatures on all responses.
      DNS_SERVER_DNSSEC_VALIDATION = "true";
      DNS_SERVER_PREFER_IPv6 = "false";
      DNS_SERVER_LOG_USING_LOCAL_TIME = "true";
    };

    # Host networking so Technitium binds directly to the host's IP on port 53.
    # Bridge networking conflicts with Podman's aardvark-dns which also uses
    # port 53 on the bridge interface (10.88.0.1:53).
    extraOptions = [
      "--network=host"
      "--env-file=/run/secrets/technitium_env"
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
