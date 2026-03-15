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

        # Home
        (mkHttp { name = "Homepage";       url = "https://homepage.theshire.io"; group = "Home"; })
        (mkHttp { name = "Home Assistant"; url = "https://ha.theshire.io";   group = "Home"; })

        # Media
        (mkHttp { name = "Jellyfin";    url = "https://jellyfin.theshire.io"; group = "Media"; })
        (mkHttp { name = "qBittorrent";  url = "https://dl.theshire.io";      group = "Media"; })
        (mkHttp { name = "SABnzbd";     url = "https://nzb.theshire.io";      group = "Media"; })
        (mkHttp { name = "Radarr";      url = "https://movies.theshire.io";   group = "Media"; })
        (mkHttp { name = "Sonarr";      url = "https://tv.theshire.io";       group = "Media"; })
        (mkHttp { name = "Prowlarr";    url = "https://prowlarr.theshire.io"; group = "Media"; })
        (mkHttp { name = "Lidarr";      url = "https://music.theshire.io";    group = "Media"; })

        # Observability
        (mkHttp { name = "Grafana";     url = "https://grafana.theshire.io";  group = "Observability"; })
        (mkHttp { name = "ntfy";        url = "https://ntfy.theshire.io";     group = "Observability"; })
      ];
    };
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
