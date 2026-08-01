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

        # Home
        (mkHttp { name = "Homepage";       url = "https://homepage.theshire.io"; group = "Home"; })
        (mkHttp { name = "Home Assistant"; url = "https://ha.theshire.io";   group = "Home"; })

        # Media
        (mkHttp { name = "Jellyfin";    url = "https://jellyfin.theshire.io"; group = "Media"; })
        # TCP check on gluetun's control port — all arr container ports (including qBT's
        # 9091) live in gluetun's network namespace, so this is the right signal for
        # "VPN container is up and the media stack has network". Complements the Caddy-
        # proxied qBittorrent check below with a direct LAN path that doesn't depend on
        # Caddy or external DNS.
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
