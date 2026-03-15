# modules/homepage.nix — Homepage dashboard
#
# Uses the native NixOS service module instead of a container, so config
# is declared entirely in Nix. No environment.etc, no volume mounts.
#
# Icons reference the dashboard-icons project bundled with Homepage.
# See https://gethomepage.dev/configs/services/ for full schema.

{ config, pkgs, lib, ... }:

{
  services.homepage-dashboard = {
    enable = true;
    listenPort = 3000;
    openFirewall = true;
    allowedHosts = "mirkwood.home.theshire.io:3000,mirkwood:3000,10.0.1.8:3000,homepage.theshire.io";

    settings = {
      title = "Homelab";
      theme = "dark";
      color = "slate";
      headerStyle = "clean";
      statusStyle = "dot";
    };

    widgets = [
      {
        datetime = {
          text_size = "xl";
          format = {
            timeStyle = "short";
            dateStyle = "short";
            hour12 = true;
          };
        };
      }
      {
        search = {
          provider = "duckduckgo";
          target = "_blank";
        };
      }
    ];

    services = [
      {
        Media = [
          {
            Jellyfin = {
              href = "https://jellyfin.theshire.io";
              description = "Media server";
              icon = "jellyfin.png";
            };
          }
        ];
      }
      {
        Downloads = [
          {
            qBittorrent = {
              href = "https://dl.theshire.io";
              description = "Torrent client";
              icon = "qbittorrent.png";
            };
          }
          {
            Radarr = {
              href = "https://movies.theshire.io";
              description = "Movie manager";
              icon = "radarr.png";
            };
          }
          {
            Sonarr = {
              href = "https://sonarr.theshire.io";
              description = "TV manager";
              icon = "sonarr.png";
            };
          }
          {
            Prowlarr = {
              href = "https://prowlarr.theshire.io";
              description = "Indexer manager";
              icon = "prowlarr.png";
            };
          }
          {
            Lidarr = {
              href = "https://lidarr.theshire.io";
              description = "Music manager";
              icon = "lidarr.png";
            };
          }
        ];
      }
      {
        Home = [
          {
            "Home Assistant" = {
              href = "https://ha.theshire.io";
              description = "Home automation";
              icon = "home-assistant.png";
            };
          }
        ];
      }
      {
        Infrastructure = [
          {
            Grafana = {
              href        = "https://grafana.theshire.io";
              description = "DNS metrics & dashboards";
              icon        = "grafana.png";
            };
          }
        ];
      }
      {
        Mirkwood = [
          {
            CPU = {
              href        = "https://mirkwood-stats.theshire.io";
              description = "Processor";
              icon        = "glances.png";
              widget = {
                type    = "glances";
                url     = "http://mirkwood.local:61208";
                metric  = "cpu";
                version = 4;
              };
            };
          }
          {
            Memory = {
              href        = "https://mirkwood-stats.theshire.io";
              description = "Memory";
              icon        = "glances.png";
              widget = {
                type    = "glances";
                url     = "http://mirkwood.local:61208";
                metric  = "memory";
                version = 4;
              };
            };
          }
          {
            Network = {
              href        = "https://mirkwood-stats.theshire.io";
              description = "Network";
              icon        = "glances.png";
              widget = {
                type    = "glances";
                url     = "http://mirkwood.local:61208";
                metric  = "network";
                adapter = "eth0";
                version = 4;
              };
            };
          }
        ];
      }
      {
        Rivendell = [
          {
            CPU = {
              href        = "https://rivendell-stats.theshire.io";
              description = "Processor";
              icon        = "glances.png";
              widget = {
                type    = "glances";
                url     = "http://rivendell.local:61208";
                metric  = "cpu";
                version = 4;
              };
            };
          }
          {
            Memory = {
              href        = "https://rivendell-stats.theshire.io";
              description = "Memory";
              icon        = "glances.png";
              widget = {
                type    = "glances";
                url     = "http://rivendell.local:61208";
                metric  = "memory";
                version = 4;
              };
            };
          }
          {
            Network = {
              href        = "https://rivendell-stats.theshire.io";
              description = "Network";
              icon        = "glances.png";
              widget = {
                type    = "glances";
                url     = "http://rivendell.local:61208";
                metric  = "network";
                adapter = "eth0";
                version = 4;
              };
            };
          }
        ];
      }
      {
        Pirateship = [
          {
            CPU = {
              href        = "https://pirateship-stats.theshire.io";
              description = "Processor";
              icon        = "glances.png";
              widget = {
                type    = "glances";
                url     = "http://pirateship.local:61208";
                metric  = "cpu";
                version = 4;
              };
            };
          }
          {
            Memory = {
              href        = "https://pirateship-stats.theshire.io";
              description = "Memory";
              icon        = "glances.png";
              widget = {
                type    = "glances";
                url     = "http://pirateship.local:61208";
                metric  = "memory";
                version = 4;
              };
            };
          }
          {
            Network = {
              href        = "https://pirateship-stats.theshire.io";
              description = "Network";
              icon        = "glances.png";
              widget = {
                type    = "glances";
                url     = "http://pirateship.local:61208";
                metric  = "network";
                adapter = "eth0";
                version = 4;
              };
            };
          }
        ];
      }
    ];

    bookmarks = [
      {
        Homelab = [
          {
            "GitHub Repo" = [
              {
                href = "https://github.com/bcrescimanno/homelab-nix";
                icon = "github.png";
              }
            ];
          }
        ];
      }
    ];
  };
}
