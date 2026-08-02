# modules/gatus.nix — Gatus service health monitor
#
# Declarative replacement for Uptime Kuma. All monitors are defined here
# in Nix — no web UI, no SQLite state, no restore script needed.
#
# Alerts publish to ntfy (127.0.0.1:2586, the homelab topic).
# Using the internal address directly avoids a dependency on Caddy being up.
#
# Port layout:
#   8080 — Gatus web UI / status page (proxied via Caddy at monitor.theshire.io)

{ config, pkgs, lib, ... }:

let
  mkHttp = { name, url, group }: {
    inherit name url group;
    interval = "1m";
    conditions = [ "[STATUS] == 200" ];
    alerts = [{ type = "ntfy"; }];
  };

  mkTcp = { name, host, group }: {
    inherit name group;
    url = "tcp://${host}:22";
    interval = "1m";
    conditions = [ "[CONNECTED] == true" ];
    alerts = [{ type = "ntfy"; }];
  };

  # DNS resolution check — verifies the resolver can actually resolve, not just that port 53 is open.
  # Uses cloudflare.com as a canary: it's globally routable, always available, and not in any blocklist.
  mkDns = { name, host, group }: {
    inherit name group;
    url = "${host}:53";
    dns = {
      "query-name" = "cloudflare.com";
      "query-type" = "A";
    };
    interval = "1m";
    conditions = [ "[DNS_RCODE] == NOERROR" ];
    alerts = [{ type = "ntfy"; }];
  };

  # Ad-blocking canary — the only end-to-end test of whether blocking WORKS.
  #
  # Every other signal is a proxy. `blocky_denylist_cache_entries` counts what
  # was loaded, and on 2026-08-01 it counted 216113 entries while
  # pagead2.googlesyndication.com resolved perfectly happily: the list had
  # loaded, it just used bare entries, which Blocky 0.34 matches as exact names
  # only. Entry-count alerting is structurally incapable of catching that class
  # of bug. Asking the resolver the question a client would ask is.
  #
  # This catches, in one check: empty lists, wrong matching semantics, blocking
  # switched off, a bad upstream, and the service being down.
  #
  # For A queries Gatus puts the resolved address in [BODY] (client.QueryDNS,
  # `case dns.TypeA`), and Blocky answers a blocked name with 0.0.0.0 NOERROR
  # — verified against both resolvers rather than assumed.
  #
  # The canary is a subdomain on purpose: an apex would pass even under the
  # bare-entry bug that prompted this. Ad-serving hosts are subdomains, so the
  # test should be one too.
  mkAdBlockCanary = { name, host, group }: {
    inherit name group;
    url = "${host}:53";
    dns = {
      "query-name" = "pagead2.googlesyndication.com";
      "query-type" = "A";
    };
    interval = "5m";
    conditions = [
      "[DNS_RCODE] == NOERROR"
      "[BODY] == 0.0.0.0"
    ];
    alerts = [{ type = "ntfy"; }];
  };
in

{
  services.gatus = {
    enable = true;
    settings = {
      web.port = 8080;

      alerting.ntfy = {
        url             = "http://127.0.0.1:2586";
        topic           = "homelab";
        priority        = 3;
        "default-alert" = {
          enabled             = true;
          "failure-threshold" = 3;
          "success-threshold" = 2;
        };
      };

      endpoints = [
        # Infrastructure — SSH reachability
        (mkTcp { name = "pirateship"; host = "pirateship"; group = "Infrastructure"; })
        (mkTcp { name = "rivendell";  host = "rivendell";  group = "Infrastructure"; })
        (mkTcp { name = "mirkwood";   host = "mirkwood";   group = "Infrastructure"; })
        (mkTcp { name = "orthanc";    host = "orthanc";    group = "Infrastructure"; })

        # DNS — resolution checks (port 53 open is not enough; verify actual recursive resolution)
        (mkDns { name = "mirkwood DNS"; host = "mirkwood"; group = "Infrastructure"; })
        (mkDns { name = "rivendell DNS"; host = "rivendell"; group = "Infrastructure"; })

        (mkAdBlockCanary { name = "mirkwood ad blocking";  host = "mirkwood";  group = "Infrastructure"; })
        (mkAdBlockCanary { name = "rivendell ad blocking"; host = "rivendell"; group = "Infrastructure"; })

        # Home
        (mkHttp { name = "Homepage";       url = "https://homepage.theshire.io"; group = "Home"; })
        (mkHttp { name = "Home Assistant"; url = "https://ha.theshire.io";   group = "Home"; })

        # Media
        (mkHttp { name = "Jellyfin";    url = "https://jellyfin.theshire.io"; group = "Media"; })
        # TCP check on gluetun's control port. This is a LIVENESS check for the
        # container and nothing more — it is NOT a tunnel check, despite the name.
        # gluetun's control server listens on `:::8000` inside the netns and does
        # not touch tun0, so this stays green with the VPN completely down.
        # Measured 2026-08-02; the control server's status routes would answer the
        # real question but every one of them returns `Unauthorized` (gluetun now
        # requires an auth config, and /var/lib/gluetun/auth/config.toml is empty).
        #
        # Whether the tunnel is actually up, and whether anything is escaping it,
        # is answered by vpn-leak-check on pirateship — see modules/vpn-killswitch.nix
        # and the `vpn` alert group in modules/grafana.nix. Keep this check for what
        # it is good at: a direct LAN path that does not depend on Caddy or DNS.
        {
          name = "gluetun VPN";
          url = "tcp://pirateship:8000";
          group = "Media";
          interval = "1m";
          conditions = [ "[CONNECTED] == true" ];
          alerts = [{ type = "ntfy"; }];
        }
        (mkHttp { name = "qBittorrent";  url = "https://dl.theshire.io";      group = "Media"; })
        (mkHttp { name = "SABnzbd";     url = "https://nzb.theshire.io";      group = "Media"; })
        (mkHttp { name = "Radarr";      url = "https://movies.theshire.io";   group = "Media"; })
        (mkHttp { name = "Sonarr";      url = "https://tv.theshire.io";       group = "Media"; })
        (mkHttp { name = "Prowlarr";    url = "https://prowlarr.theshire.io"; group = "Media"; })
        (mkHttp { name = "Lidarr";      url = "https://music.theshire.io";    group = "Media"; })
        (mkHttp { name = "Music Assistant"; url = "https://listen.theshire.io"; group = "Media"; })

        # Gaming
        {
          name = "Minecraft — Prominence II";
          url = "tcp://orthanc:25565";
          group = "Gaming";
          interval = "1m";
          conditions = [ "[CONNECTED] == true" ];
          alerts = [{ type = "ntfy"; }];
        }
        {
          name = "Minecraft — Abyssal Ascent";
          url = "tcp://orthanc:25566";
          group = "Gaming";
          interval = "1m";
          conditions = [ "[CONNECTED] == true" ];
          alerts = [{ type = "ntfy"; }];
        }

        # Invidious — availability, then a real playback probe.
        #
        # The availability check alone is close to worthless here: the way this
        # service fails is companion's po_token going stale, after which the
        # unit stays active, every page still renders, and only the stream URLs
        # come back empty. That is the same "healthy while broken" shape as the
        # alertmanager /alert 404 and the NUT /metrics path. So the probe below
        # asserts on the streams themselves.
        (mkHttp { name = "Invidious"; url = "https://invidious.theshire.io"; group = "Media"; })
        {
          name = "Invidious playback";
          # Stable, not age- or region-restricted. If this video ever goes away
          # the monitor will false-alarm — swap the ID, don't weaken the
          # conditions.
          url = "https://invidious.theshire.io/api/v1/videos/dQw4w9WgXcQ";
          group = "Media";

          # MUST stay above 10 minutes. src/invidious/videos.cr:298-317 only
          # re-fetches from YouTube when the cached row is older than 10min;
          # anything faster is answered from the `videos` table and would pass
          # happily while live extraction is completely broken. 15m guarantees
          # every run exercises the real companion path. (On a failed refresh
          # Invidious deletes the cached row and re-raises, so there is no stale
          # fallback to mask it.)
          interval = "15m";

          # Verified with a NEGATIVE test against a video that returns 200 with
          # an empty body — [STATUS] PASSED while both body conditions FAILED
          # (`len([BODY].adaptiveFormats) (0) > 10`). A status-only check, i.e.
          # every other mkHttp in this file, calls that broken case healthy.
          conditions = [
            # Catches a hard failure: the API returns 500 + error_json when
            # fetch_video raises "Invidious companion is not available".
            "[STATUS] == 200"

            # Status is NOT sufficient on its own — see the negative test above.
            "len([BODY].adaptiveFormats) > 10"

            # The actual Piped failure signature, encoded: video streams present
            # but ZERO audio streams. A format list without any audio/* entry
            # means nothing can play, and that is exactly what a dead extractor
            # produces.
            "[BODY] == pat(*audio/*)"
          ];
          alerts = [{ type = "ntfy"; }];
        }

        # Observability
        (mkHttp { name = "Grafana";     url = "https://grafana.theshire.io";  group = "Observability"; })
        (mkHttp { name = "ntfy";        url = "https://ntfy.theshire.io";     group = "Observability"; })

        # Nix binary cache — functional probe via the standard nix-cache-info
        # endpoint. Asserts StoreDir is correct so signing key mismatches,
        # wrong cache name, and atticd config drift all surface as alerts.
        {
          name = "Nix Cache";
          url = "https://cache.theshire.io/nixpkgs/nix-cache-info";
          group = "Observability";
          interval = "5m";
          conditions = [
            "[STATUS] == 200"
            "[BODY] == pat(*nix/store*)"
          ];
          alerts = [{ type = "ntfy"; }];
        }
      ];
    };
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];

  homelab.postUpgradeCheck.services = [ "gatus" ];
}
