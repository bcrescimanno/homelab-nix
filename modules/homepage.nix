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
    allowedHosts = "mirkwood.local:3000,mirkwood:3000,10.0.1.8:3000,home.theshire.io";

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
            Transmission = {
              href = "https://dl.theshire.io";
              description = "Torrent client";
              icon = "transmission.png";
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
        Monitoring = [
          {
            "Glances (mirkwood)" = {
              href = "https://mirkwood-stats.theshire.io";
              description = "System monitor";
              icon = "glances.png";
            };
          }
          {
            "Glances (rivendell)" = {
              href = "https://rivendell-stats.theshire.io";
              description = "System monitor";
              icon = "glances.png";
            };
          }
          {
            "Glances (pirateship)" = {
              href = "https://pirateship-stats.theshire.io";
              description = "System monitor";
              icon = "glances.png";
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
