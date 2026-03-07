# modules/homepage.nix — Homepage dashboard
#
# Config files are Nix-managed via environment.etc and mounted read-only
# into the container at /app/config. Homepage writes logs to
# /app/config/logs/, so a separate writable mount overlays that
# subdirectory. Any config change requires a nixos-rebuild + container
# restart to take effect.
#
# Icons reference the dashboard-icons project bundled with Homepage.
# See https://gethomepage.dev/configs/services/ for full schema.

{ config, pkgs, lib, ... }:

{
  virtualisation.oci-containers.containers.homepage = {
    image = "ghcr.io/gethomepage/homepage:latest";
    autoStart = true;
    volumes = [
      # Nix-managed config (read-only); logs subdir overlaid below.
      "/etc/homepage:/app/config:ro"
      "/var/lib/homepage/logs:/app/config/logs"
    ];
    ports = [
      "3000:3000/tcp"
    ];
  };

  environment.etc = {
    "homepage/settings.yaml".text = ''
      title: Homelab
      theme: dark
      color: slate
      headerStyle: clean
      statusStyle: dot
    '';

    "homepage/widgets.yaml".text = ''
      - datetime:
          text_size: xl
          format:
            timeStyle: short
            dateStyle: short
            hour12: true
      - search:
          provider: duckduckgo
          target: _blank
    '';

    "homepage/services.yaml".text = ''
      - Media:
          - Jellyfin:
              href: http://pirateship:8096
              description: Media server
              icon: jellyfin.png

      - Downloads:
          - Transmission:
              href: http://pirateship:9091
              description: Torrent client
              icon: transmission.png
          - Radarr:
              href: http://pirateship:7878
              description: Movie manager
              icon: radarr.png
          - Sonarr:
              href: http://pirateship:8989
              description: TV manager
              icon: sonarr.png
          - Prowlarr:
              href: http://pirateship:9696
              description: Indexer manager
              icon: prowlarr.png
          - Lidarr:
              href: http://pirateship:8686
              description: Music manager
              icon: lidarr.png

      - Home:
          - Home Assistant:
              href: http://rivendell:8123
              description: Home automation
              icon: home-assistant.png

      - Infrastructure:
          - Technitium (mirkwood):
              href: http://mirkwood:5380
              description: Primary DNS
              icon: technitium-dns-server.png
          - Technitium (rivendell):
              href: http://rivendell:5380
              description: Secondary DNS
              icon: technitium-dns-server.png
          - Nginx Proxy Manager:
              href: http://rivendell:81
              description: Reverse proxy
              icon: nginx-proxy-manager.png

      - Monitoring:
          - Glances (mirkwood):
              href: http://mirkwood:61208
              description: System monitor
              icon: glances.png
          - Glances (rivendell):
              href: http://rivendell:61208
              description: System monitor
              icon: glances.png
    '';

    "homepage/bookmarks.yaml".text = ''
      - Homelab:
          - GitHub Repo:
              - href: https://github.com/bcrescimanno/homelab-nix
                icon: github.png
    '';

    "homepage/docker.yaml".text = '''';
  };

  networking.firewall.allowedTCPPorts = [ 3000 ];

  systemd.tmpfiles.rules = [
    "d /var/lib/homepage/logs 0755 root root -"
  ];
}
