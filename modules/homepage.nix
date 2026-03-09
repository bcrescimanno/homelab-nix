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
              href = "http://pirateship:8096";
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
              href = "http://pirateship:9091";
              description = "Torrent client";
              icon = "transmission.png";
            };
          }
          {
            Radarr = {
              href = "http://pirateship:7878";
              description = "Movie manager";
              icon = "radarr.png";
            };
          }
          {
            Sonarr = {
              href = "http://pirateship:8989";
              description = "TV manager";
              icon = "sonarr.png";
            };
          }
          {
            Prowlarr = {
              href = "http://pirateship:9696";
              description = "Indexer manager";
              icon = "prowlarr.png";
            };
          }
          {
            Lidarr = {
              href = "http://pirateship:8686";
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
              href = "http://rivendell:8123";
              description = "Home automation";
              icon = "home-assistant.png";
            };
          }
        ];
      }
      {
        Infrastructure = [
          {
            "Technitium (mirkwood)" = {
              href = "http://mirkwood:5380";
              description = "Primary DNS";
              icon = "technitium-dns-server.png";
            };
          }
          {
            "Technitium (rivendell)" = {
              href = "http://rivendell:5380";
              description = "Secondary DNS";
              icon = "technitium-dns-server.png";
            };
          }
          {
            "Nginx Proxy Manager" = {
              href = "http://rivendell:81";
              description = "Reverse proxy";
              icon = "nginx-proxy-manager.png";
            };
          }
        ];
      }
      {
        Monitoring = [
          {
            "Glances (mirkwood)" = {
              href = "http://mirkwood:61208";
              description = "System monitor";
              icon = "glances.png";
            };
          }
          {
            "Glances (rivendell)" = {
              href = "http://rivendell:61208";
              description = "System monitor";
              icon = "glances.png";
            };
          }
          {
            "Glances (pirateship)" = {
              href = "http://pirateship:61208";
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
