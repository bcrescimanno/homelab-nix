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

      # ---------------------------------------------------------------------
      # Force IPv4 for Blocky's own OUTBOUND connections (upstream DoH +
      # blocklist downloads). This is not a preference — it is load-bearing.
      #
      # Both DNS hosts have ULA-only IPv6 (mirkwood fd0a:7e1:5e:1::8,
      # rivendell ::9). ULA is private and NOT globally routable, but Linux
      # still tags it `scope global`, so Blocky concludes IPv6 works, resolves
      # AAAA for big.oisd.nl / phishing.army, dials IPv6 and hangs until the
      # download timeout. Measured on mirkwood 2026-08-25:
      #   curl -6 https://phishing.army/...  -> HTTP 000 after 25s (hung)
      #   curl -4 (same URL, same host)      -> HTTP 200, 3.2MB, 0.26s
      #
      # Why this key fixes it, from the blocky 0.34 source: the blocklist
      # downloader is built as
      #   lists.NewDownloader(cfg.Loading.Downloads, bootstrap.NewHTTPTransport())
      # and NewHTTPTransport sets DialContext = bootstrap.dialContext, which
      # resolves via `connectIPVersion.QTypes()`. "v4" makes that return A
      # records only, so the downloader never dials IPv6.
      # Accepted values are dual | v4 | v6 (NOT "ipv4" / "ip4").
      #
      # This failed SILENTLY from ~2026-08-24: a running Blocky keeps serving
      # from cached lists, so the only symptom was list-refresh WARNs in the
      # journal. It surfaced on 2026-08-25 when a deploy restarted Blocky and
      # it would not bind port 53 for ~4 min on each host.
      # ---------------------------------------------------------------------
      connectIPVersion = "v4";

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
        # SOURCE URLS — the HaGeZi lists that used to be here are GONE.
        # On 2026-08-09 the entire `hagezi` GitHub ACCOUNT disappeared: both
        # https://api.github.com/users/hagezi and every repo under it return
        # 404, verified from two hosts while control repos (NixOS/nixpkgs)
        # returned 200 on the same calls. This is not the old 403/restructure
        # problem and it is not transient — there is no upstream left to retry.
        # Symptom at the time: `blocky_denylist_cache_entries{group="ads"}` = 7
        # (the inline entries below and nothing else) and `{group="malware"}` = 0.
        # Do NOT "fix" this by pointing back at cdn.jsdelivr.net — jsDelivr was
        # still serving a complete cached copy for a few hours after the origin
        # died, which makes it look like a working source right up until the CDN
        # revalidates against a dead origin and starts 404ing too.
        #
        # Replaced with oisd (independently hosted, not on GitHub, hourly
        # rebuilds). Pick the `domainswild` variant, NOT `domainswild2`:
        # oisd publishes the same entry set in both syntaxes, `domainswild` as
        # `*.example.com` and `domainswild2` as bare `example.com`. This is the
        # same trap hagezi had, for the same reason:
        #
        # WHY: a bare denylist entry in Blocky 0.34 matches that name ONLY.
        # It does NOT cover subdomains, despite what is widely assumed.
        # Measured on the running host via Blocky's own query log:
        #   googlesyndication.com.          -> BLOCKED (ads: googlesyndication.com)
        #   pagead2.googlesyndication.com.  -> RESOLVED (142.251.219.2)
        # `*.example.com` blocks the apex AND every subdomain, which is what the
        # oisd entry set is collapsed to assume — its own header says so:
        # `"*.example.com" should block "example.com" and "subdomain.example.com"`.
        # Bare entries silently give a fraction of the intended coverage — the
        # ad-serving hosts are almost always subdomains (pagead2., googleads.g.,
        # s0.), not the apex.
        denylists = {
          # oisd big — ads, trackers, telemetry, AND malware/phishing/ransomware/
          # cryptojacking (~253k wildcard entries, rebuilt hourly). Tuned for
          # "block, don't break", so the false-positive rate is low.
          ads = [
            "https://big.oisd.nl/domainswild"
            # oisd, like HaGeZi Pro before it, intentionally omits these Google
            # ad apexes to avoid
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

              # Windows WPAD (Web Proxy Auto-Discovery) suppression. Windows
              # polls for a proxy config script continuously; without a clean
              # NXDOMAIN it bypasses cache and hammers DNS. No proxy exists on
              # this network so these should never resolve.
              #
              # These lived in their own `local-noise` group until 2026-08-04.
              # They are folded in here because a group with ONLY inline sources
              # needs no network, so it succeeds on every refresh cycle — and
              # `blocky_last_list_group_refresh_timestamp_seconds` is a single
              # global gauge that ANY succeeding group advances (see
              # lists/list_cache.go: the event is published per group, on the
              # success path only). An inline-only group therefore pinned that
              # gauge to "now" every 4h forever, which silently made the
              # BlocklistStale alert in modules/grafana.nix incapable of ever
              # firing. Every denylist group must depend on the network for that
              # backstop to mean anything. Do not re-add an inline-only group.
              wpad.theshire.io
              wpad.home.theshire.io
            ''
          ];
          # Phishing Army (extended) — phishing and fraud domains, ~156k entries.
          #
          # This group is now DEFENCE IN DEPTH, not the primary threat coverage:
          # oisd big above already includes malware/phishing/ransomware/
          # cryptojacking, and it does so in `*.` wildcard syntax. The group is
          # kept for two reasons: it is a genuinely independent feed (different
          # maintainer, different infrastructure, so one dead upstream no longer
          # takes out threat blocking entirely), and ThreatBlocklistEmpty in
          # modules/grafana.nix alerts per group — collapsing to a single group
          # would silently retire that alert.
          #
          # CAVEAT: Phishing Army publishes BARE domains, so per the matching
          # note above these entries match the exact name only, not subdomains.
          # That is an accepted tradeoff here — phishing feeds list the exact
          # observed FQDN rather than an apex to wildcard — but it is why this
          # is the supplement and oisd is the primary. If a `*.`-syntax threat
          # feed turns up, prefer it.
          malware = [
            "https://phishing.army/download/phishing_army_blocklist_extended.txt"
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
        clientGroupsBlock.default = [ "ads" "malware" ];

        # The lists are large (~253k + ~156k entries); the default download
        # timeout can truncate one mid-body on a slow fetch. Give downloads
        # more time and retries so lists always load complete.
        loading.downloads = {
          timeout  = "60s";
          attempts = 5;
          cooldown = "10s";
        };

        # Serve DNS IMMEDIATELY and load blocklists in the background.
        #
        # The default is "blocking", which will not bind port 53 until every
        # list has downloaded or exhausted `attempts`. With the retry budget
        # above (5 attempts x 60s timeout + 10s cooldown) a single unreachable
        # source can hold DNS down for minutes — which is exactly what happened
        # on 2026-08-25, on both DNS hosts, from the ULA/IPv6 stall above.
        #
        # connectIPVersion fixes that specific cause; this makes the class of
        # failure non-fatal. DNS availability must never depend on a third-party
        # list host being reachable — hagezi's entire GitHub account vanishing
        # on 2026-08-09 is the precedent for a source disappearing outright.
        #
        # Trade-off: for the first few seconds after a restart Blocky answers
        # with empty denylists, so a handful of ad domains resolve. That is
        # strictly better than answering nothing at all. A source that fails
        # PERMANENTLY still surfaces via the blocky_denylist_cache_entries
        # alert thresholds rather than by taking DNS down.
        # Canonical key: `startStrategy` is DEPRECATED in 0.34 and silently
        # migrated to blocking.loading.strategy — set the real one.
        loading.strategy = "fast";
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
  # This unit rolled back a good deploy on 2026-08-29, and the way it did it is
  # worth keeping written down.
  #
  # Its 2-min timer fired mid-activation. unbound was restarting (nixpkgs bump),
  # so the single dig failed and the check declared "failed". It then curled
  # ntfy to say so — but ntfy was restarting in the SAME activation, so curl
  # retried 3x over 30s and exited 7. `script` runs under set -e, so curl's
  # status became the unit's status, the unit failed, switch-to-configuration
  # exited non-zero, and deploy-rs autoRollback tore down a perfectly good
  # generation (and then failed to re-activate the old one, leaving the host
  # running one closure with its profile pointing at another).
  #
  # Three separate faults, fixed below:
  #
  #   1. A single dig is not a finding. unbound restarts on every deploy and
  #      this timer fires every 2 min, so a bare probe reports the restart as an
  #      outage. It now re-probes after a grace period before deciding.
  #   2. The state file was written BEFORE the notification, so an undelivered
  #      alert was lost for good — 11:22 got no "failure" push, and 11:24 then
  #      sent a bare "recovered" for an event never reported. State is now
  #      written only once the push is actually delivered, so a failed send
  #      retries on the next run instead of vanishing.
  #   3. Push transport is not DNS health. A failure to reach ntfy must not fail
  #      this unit, because a timer-driven oneshot that fails inside the
  #      activation window rolls back the deploy. It logs and exits 0.
  systemd.services.unbound-health-check = {
    description = "Unbound DNS health check";
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "unbound-monitor";
      # Worst case: grace sleep + a fully-retried curl.
      TimeoutStartSec = "120s";
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

        probe() {
          ${dig} @127.0.0.1 -p 5335 +time=5 +tries=1 cloudflare.com A >/dev/null 2>&1
        }

        # Re-probe before calling it an outage; see fault 1 above. A real
        # outage still alerts on this run or the next one 2 min later.
        if probe; then
          NOW=ok
        else
          sleep 20
          if probe; then NOW=ok; else NOW=failed; fi
        fi

        [ "$NOW" = "$LAST" ] && exit 0

        if [ "$NOW" = failed ]; then
          TITLE='Unbound DNS failure'; PRIO=4; TAGS=rotating_light
          BODY='${host}: unbound cannot resolve — Blocky may be falling back to 1.1.1.1'
        else
          TITLE='Unbound DNS recovered'; PRIO=2; TAGS=white_check_mark
          BODY='${host}: unbound is resolving normally again'
        fi

        # State advances only on a delivered push (fault 2), and a transport
        # failure never fails the unit (fault 3).
        if ${curl} -sf --connect-timeout 5 --max-time 30 \
             --retry 3 --retry-delay 10 --retry-all-errors \
             -H "Title: $TITLE" -H "Priority: $PRIO" -H "Tags: $TAGS" \
             -d "$BODY" ${ntfy} >/dev/null; then
          echo "$NOW" > "$STATE_FILE"
        else
          echo "ntfy delivery failed; leaving state at '$LAST' so '$NOW' is retried" >&2
        fi
        exit 0
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
