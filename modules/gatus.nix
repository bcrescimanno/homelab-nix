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
          name = "Minecraft";
          url = "tcp://orthanc:25565";
          group = "Gaming";
          interval = "1m";
          conditions = [ "[CONNECTED] == true" ];
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
            "[BODY] contains StoreDir: /nix/store"
          ];
          alerts = [{ type = "ntfy"; }];
        }
      ];
    };
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
