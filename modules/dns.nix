# modules/dns.nix — Blocky (DNS blocker/proxy) + Unbound (recursive resolver)
#
# Replaces Technitium DNS container with a fully declarative stack.
# Runs identically on mirkwood (primary) and rivendell (secondary) —
# no zone sync required; the Nix config is the source of truth.
#
# Blocky handles: ad blocking, conditional forwarding (.local → UDM Pro),
#   DoH server (port 4000), Prometheus metrics (/metrics on port 4000)
# Unbound handles: recursive resolution to root servers, DNSSEC validation,
#   and the theshire.io split-horizon zone via local-zone/local-data
#
# Port layout:
#   53    — DNS (TCP+UDP, all clients)
#   4000  — Blocky HTTP: DoH (/dns-query) + metrics (/metrics)
#   5335  — Unbound (localhost only, not in firewall)

{ config, pkgs, lib, ... }:

{
  services.unbound = {
    enable = true;
    settings.server = {
      interface      = [ "127.0.0.1" ];
      port           = 5335;
      access-control = [ "127.0.0.1/32 allow" ];
      do-ip4         = true;
      do-ip6         = false;
      do-udp         = true;
      do-tcp         = true;
      hide-identity  = true;
      hide-version   = true;

      # Split-horizon DNS for theshire.io.
      # redirect zone type acts as a wildcard: all *.theshire.io queries return
      # the apex A record (10.0.1.9 = Caddy on rivendell).
      # erebor gets its own static zone (more-specific zones take priority).
      local-zone = [
        ''"theshire.io." redirect''
        ''"erebor.theshire.io." static''
      ];
      local-data = [
        ''"theshire.io. 3600 IN A 10.0.1.9"''
        ''"erebor.theshire.io. 3600 IN A 10.0.1.22"''
      ];
    };
  };

  services.blocky = {
    enable = true;
    settings = {

      ports = {
        dns  = 53;
        http = 4000;    # DoH (/dns-query) + Prometheus metrics (/metrics)
      };

      upstreams.groups.default = [ "127.0.0.1:5335" ];

      # Bootstrap for initial blocklist downloads before Unbound is ready
      bootstrapDns = {
        upstream = "https://1.1.1.1/dns-query";
        ips      = [ "1.1.1.1" "1.0.0.1" ];
      };

      blocking = {
        denylists.ads = [
          "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
        ];
        clientGroupsBlock.default = [ "ads" ];
      };

      # Forward .local and reverse-DNS queries to UDM Pro for DHCP hostname resolution
      conditional.mapping = {
        "local"                = "10.0.1.1";
        "1.0.10.in-addr.arpa" = "10.0.1.1";
      };

      # Resolve client IPs to hostnames for Grafana panels and query logs.
      # UDM Pro has PTR records for all DHCP leases.
      # Static mappings for Podman containers (10.88.x.x, no PTR records).
      clientLookup = {
        upstream = "10.0.1.1";
        clients = {
          "uptime-kuma" = [ "10.88.0.6" ];
        };
      };

      prometheus.enable = true;

      queryLog = {
        type             = "csv";
        target           = "/var/log/blocky";
        logRetentionDays = 30;
      };

      log.level = "warn";
    };
  };

  # Ensure Blocky starts after Unbound is ready, not just started
  systemd.services.blocky.after = [ "unbound.service" ];
  systemd.services.blocky.requires = [ "unbound.service" ];

  systemd.tmpfiles.rules = [
    "d /var/log/blocky 0755 blocky blocky -"
  ];

  networking.firewall = {
    allowedTCPPorts = [ 53 4000 ];
    allowedUDPPorts = [ 53 ];
  };
}
