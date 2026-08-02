# modules/dns.nix — Blocky (DNS blocker/proxy) + Unbound (recursive resolver)
#
# Replaces Technitium DNS container with a fully declarative stack.
# Runs identically on mirkwood (primary) and rivendell (secondary) —
# no zone sync required; the Nix config is the source of truth.
#
# Blocky handles: ad blocking, conditional forwarding (.theshire.io → UDM Pro),
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

      # Keep the cache warm: refresh popular records (and their DNSSEC keys)
      # shortly before they expire so client queries hit cache, not the network.
      prefetch       = true;
      prefetch-key   = true;

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
        # strict strategy: try unbound first (recursive + DNSSEC), then fall
        # back to DoH. DoH uses port 443 which avoids ISP UDP/53 interception
        # or cable modem states that break plain DNS while leaving HTTPS intact.
        groups.default = [
          "127.0.0.1:5335"
          "https://1.1.1.1/dns-query"
          "https://1.0.0.1/dns-query"
        ];
        strategy = "strict";
        timeout = "5s";
      };

      # Bootstrap for initial blocklist downloads before Unbound is ready
      bootstrapDns = {
        upstream = "https://1.1.1.1/dns-query";
        ips      = [ "1.1.1.1" "1.0.0.1" ];
      };

      blocking = {
        # SOURCE URLS — do not "modernise" these back to cdn.jsdelivr.net.
        # jsDelivr refuses the whole hagezi repo with HTTP 403 ("Package size
        # exceeded the configured limit of 150 MB"); the repo is ~157 MB and only
        # grows, so that is permanent, not transient. It broke silently on
        # 2026-07-31 — Blocky keeps serving with an EMPTY list rather than
        # failing, so ads came back with no alert and no unhealthy unit.
        # hagezi also restructured: the old `domains/` directory is gone. Its
        # replacements come in two syntaxes holding the SAME entry set —
        # `wildcard/<list>-onlydomains.txt` (bare `example.com`) and
        # `wildcard/<list>.txt` (`*.example.com`). Use the `*.` one.
        #
        # WHY: a bare denylist entry in Blocky 0.34 matches that name ONLY.
        # It does NOT cover subdomains, despite what is widely assumed.
        # Measured on the running host via Blocky's own query log:
        #   googlesyndication.com.          -> BLOCKED (ads: googlesyndication.com)
        #   pagead2.googlesyndication.com.  -> RESOLVED (142.251.219.2)
        # `*.example.com` blocks the apex AND every subdomain, which is what the
        # hagezi entry set is collapsed to assume. Bare entries silently give a
        # fraction of the intended coverage — the ad-serving hosts are almost
        # always subdomains (pagead2., googleads.g., s0.), not the apex.
        denylists = {
          # HaGeZi Pro — the main ads + trackers list. Aggressive coverage with
          # a low false-positive rate; well maintained.
          ads = [
            "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.txt"
            # HaGeZi Pro intentionally omits these Google ad apexes to avoid
            # breaking Google services. We block them anyway for fuller ad
            # coverage (small risk: Google "sponsored" link / Shopping clicks).
            # Wildcarded for the reason above: googleads.g.doubleclick.net is
            # the host that actually serves the ads, and a bare `doubleclick.net`
            # entry left it resolving.
            ''
              *.doubleclick.net
              *.googleadservices.com
              *.googlesyndication.com
              *.2mdn.net
              *.googletagservices.com
            ''
          ];
          # HaGeZi Threat Intelligence Feeds — malware, phishing, cryptojacking,
          # scam, and other actively-malicious domains.
          malware = [
            "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif.txt"
          ];
          # Suppress Windows WPAD (Web Proxy Auto-Discovery) queries.
          # Windows polls for a proxy config script continuously; without a clean
          # NXDOMAIN it bypasses cache and hammers DNS. No proxy exists on this
          # network so these should never resolve.
          local-noise = [
            ''
              wpad.theshire.io
              wpad.home.theshire.io
            ''
          ];
        };
        # False-positive recovery. Add a domain here (one per line) to un-block
        # it from the matching group when a blocklist is too aggressive.
        allowlists = {
          ads = [
            ''
              # Add false-positive domains here, one per line.
            ''
          ];
        };
        clientGroupsBlock.default = [ "ads" "malware" "local-noise" ];

        # The HaGeZi TIF list is very large (>1M domains); the default download
        # timeout can truncate it mid-body on a slow CDN fetch. Give downloads
        # more time and retries so lists always load complete.
        loading.downloads = {
          timeout  = "60s";
          attempts = 5;
          cooldown = "10s";
        };
      };

      # Static entries for machines with DHCP reservations — resolves immediately
      # without waiting for UDM Pro to have an active lease (e.g. after WoL).
      customDNS.mapping = {
        "terra.home.theshire.io" = "10.0.1.215";
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

      # Keep frequently-queried entries warm: Blocky re-resolves popular names
      # shortly before their TTL expires, so clients get cache hits instead of
      # waiting on an upstream lookup.
      caching = {
        prefetching = true;
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

  homelab.postUpgradeCheck.services = [ "blocky" "unbound" ];
}
