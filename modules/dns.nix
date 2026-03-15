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

      upstreams = {
        # strict strategy: try unbound first, fall back to 1.1.1.1 if unbound
        # can't prime its DNSSEC trust anchor or otherwise fails to respond
        groups.default = [ "127.0.0.1:5335" "1.1.1.1" ];
        strategy = "strict";
        timeout = "5s";
      };

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

      # Forward home.theshire.io and reverse-DNS queries to UDM Pro for DHCP hostname resolution
      conditional.mapping = {
        "home.theshire.io"     = "10.0.1.1";
        "1.0.10.in-addr.arpa" = "10.0.1.1";
      };

      # Resolve client IPs to hostnames for Grafana panels and query logs.
      # UDM Pro has PTR records for all DHCP leases.
      clientLookup = {
        upstream = "10.0.1.1";
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

  # Probe unbound health every 2 minutes. Sends ntfy alerts only on state
  # transitions (ok→failed, failed→ok) to avoid notification spam.
  # Probes port 5335 directly so Blocky's fallback to 1.1.1.1 doesn't mask failures.
  systemd.services.unbound-health-check = {
    description = "Unbound DNS health check";
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "unbound-monitor";
    };
    script =
      let
        dig  = "${pkgs.dnsutils}/bin/dig";
        curl = "${pkgs.curl}/bin/curl";
        host = config.networking.hostName;
        ntfy = "http://10.0.1.9:2586/homelab";
      in ''
        STATE_FILE=/var/lib/unbound-monitor/state
        LAST=$(cat "$STATE_FILE" 2>/dev/null || echo ok)

        if ${dig} @127.0.0.1 -p 5335 +time=5 +tries=1 cloudflare.com A >/dev/null 2>&1; then
          NOW=ok
        else
          NOW=failed
        fi

        [ "$NOW" = "$LAST" ] && exit 0
        echo "$NOW" > "$STATE_FILE"

        if [ "$NOW" = failed ]; then
          ${curl} -s --connect-timeout 5 --max-time 30 --retry 3 --retry-delay 10 --retry-all-errors \
            -H 'Title: Unbound DNS failure' -H 'Priority: 4' -H 'Tags: rotating_light' \
            -d '${host}: unbound cannot resolve — Blocky may be falling back to 1.1.1.1' \
            ${ntfy}
        else
          ${curl} -s --connect-timeout 5 --max-time 30 --retry 3 --retry-delay 10 --retry-all-errors \
            -H 'Title: Unbound DNS recovered' -H 'Priority: 2' -H 'Tags: white_check_mark' \
            -d '${host}: unbound is resolving normally again' \
            ${ntfy}
        fi
      '';
  };

  systemd.timers.unbound-health-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "2min";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/log/blocky 0755 blocky blocky -"
  ];

  networking.firewall = {
    allowedTCPPorts = [ 53 4000 ];
    allowedUDPPorts = [ 53 ];
  };
}
