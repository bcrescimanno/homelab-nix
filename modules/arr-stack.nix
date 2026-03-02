# modules/arr-stack.nix — VPN-connected container stack
#
# All arr containers share gluetun's network namespace. If the VPN
# drops, all containers lose connectivity — this is the kill switch.

{ config, pkgs, lib, ... }:

{
  virtualisation.oci-containers.backend = "podman";

  virtualisation.oci-containers.containers = {

    gluetun = {
      image = "ghcr.io/qdm12/gluetun:latest";
      autoStart = true;
      volumes = [
        "/var/lib/gluetun:/gluetun"
      ];

      environment = {
        VPN_SERVICE_PROVIDER = "protonvpn";
        VPN_TYPE = "wireguard";
        # Server endpoint hostname only — port comes from the secret
        SERVER_COUNTRIES = "United States";
        VPN_PORT_FORWARDING = "on";
        HTTP_CONTROL_SERVER_AUTH = "none";
      };

      extraOptions = [
        "--cap-add=NET_ADMIN"
        "--device=/dev/net/tun:/dev/net/tun"
        "--env-file=/run/secrets/vpn_env"
      ];

      ports = [
        "8000:8000"   # gluetun control server
        "8888:8888"   # gluetun HTTP proxy
        "8388:8388"   # gluetun Shadowsocks
        "8080:8080"   # qBittorrent web UI
        "7878:7878"   # Radarr
        "8989:8989"   # Sonarr
        "9696:9696"   # Prowlarr
      ];
    };

    qbittorrent = {
      image = "lscr.io/linuxserver/qbittorrent:latest";
      autoStart = true;
      dependsOn = [ "gluetun" ];
      extraOptions = [ "--network=container:gluetun" ];
      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Los_Angeles";
        WEBUI_PORT = "8080";
      };
      volumes = [
        "/var/lib/qbittorrent/config:/config"
        "/var/lib/media/torrents:/downloads"
      ];
    };

    radarr = {
      image = "lscr.io/linuxserver/radarr:latest";
      autoStart = true;
      dependsOn = [ "gluetun" ];
      extraOptions = [ "--network=container:gluetun" ];
      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Los_Angeles";
      };
      volumes = [
        "/var/lib/radarr/config:/config"
        "/var/lib/media/movies:/movies"
        "/var/lib/media/torrents:/downloads"
      ];
    };

    sonarr = {
      image = "lscr.io/linuxserver/sonarr:latest";
      autoStart = true;
      dependsOn = [ "gluetun" ];
      extraOptions = [ "--network=container:gluetun" ];
      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Los_Angeles";
      };
      volumes = [
        "/var/lib/sonarr/config:/config"
        "/var/lib/media/tv:/tv"
        "/var/lib/media/torrents:/downloads"
      ];
    };

    prowlarr = {
      image = "lscr.io/linuxserver/prowlarr:latest";
      autoStart = true;
      dependsOn = [ "gluetun" ];
      extraOptions = [ "--network=container:gluetun" ];
      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Los_Angeles";
      };
      volumes = [
        "/var/lib/prowlarr/config:/config"
      ];
    };

  };

  systemd.services.qbittorrent-port-sync = {
  description = "Sync gluetun forwarded port to qBittorrent";
  after = [ "podman-gluetun.service" "podman-qbittorrent.service" ];
  wantedBy = [ "multi-user.target" ];
  
  serviceConfig = {
    Type = "simple";
    Restart = "always";
    RestartSec = "30s";
    EnvironmentFile = "/run/secrets/qbt_credentials";
  };

  script = ''
    set -e
    
    # Get forwarded port from gluetun control server
    PORT=$(${pkgs.curl}/bin/curl -sf http://localhost:8000/v1/openvpn/portforwarded | ${pkgs.jq}/bin/jq -r '.port')
    
    if [ -z "$PORT" ] || [ "$PORT" = "0" ] || [ "$PORT" = "null" ]; then
      echo "No forwarded port available yet, waiting..."
      sleep 30
      exit 1
    fi
    
    echo "Forwarded port: $PORT"
    
    # Login to qBittorrent and get session cookie
    SID=$(${pkgs.curl}/bin/curl -sf -c - \
      --data "username=$QBT_USERNAME&password=$QBT_PASSWORD" \
      http://localhost:8080/api/v2/auth/login | grep SID | awk '{print $7}')
    
    # Update listening port
    ${pkgs.curl}/bin/curl -sf \
      -b "SID=$SID" \
      --data 'json={"listen_port":'"$PORT"'}' \
      http://localhost:8080/api/v2/app/setPreferences
    
    echo "Updated qBittorrent listening port to $PORT"
    
    # Check every 5 minutes for port changes
    sleep 300
  '';
};

  systemd.tmpfiles.rules = [
    "d /var/lib/qbittorrent/config 0755 brian users -"
    "d /var/lib/radarr/config 0755 brian users -"
    "d /var/lib/sonarr/config 0755 brian users -"
    "d /var/lib/prowlarr/config 0755 brian users -"
    "d /var/lib/media/torrents 0755 brian users -"
    "d /var/lib/media/movies 0755 brian users -"
    "d /var/lib/media/tv 0755 brian users -"
    "d /var/lib/gluetun/auth 0755 brian users -"
    "f /var/lib/gluetun/auth/config.toml 0644 brian users -"
  ];
}
