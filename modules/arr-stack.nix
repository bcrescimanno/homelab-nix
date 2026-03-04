# modules/arr-stack.nix — VPN-connected container stack
#
# All arr containers share gluetun's network namespace. If the VPN
# drops, all containers lose connectivity — this is the kill switch.

{ config, pkgs, lib, ... }:

{
  virtualisation.oci-containers.backend = "podman";

  virtualisation.oci-containers.containers = {

    gluetun = {
      image = "ghcr.io/qdm12/gluetun:latest@sha256:3e439a7ff285f5782278881675d90ac3b17733e591c68fa7097fa84769ef0e6c";
      autoStart = true;
      volumes = [
        "/var/lib/gluetun:/gluetun"
        "/var/lib/gluetun/tmp:/tmp/gluetun"
      ];

      environment = {
        VPN_SERVICE_PROVIDER = "protonvpn";
        VPN_TYPE = "wireguard";
        SERVER_COUNTRIES = "Netherlands";
        VPN_PORT_FORWARDING = "on";
        PORT_FORWARD_ONLY = "on";
        WIREGUARD_IMPLEMENTATION = "userspace";
        BLOCK_MALICIOUS = "off";
        WIREGUARD_MTU = "1280";
      };

      extraOptions = [
        "--privileged"
        "--device=/dev/net/tun:/dev/net/tun"
        "--env-file=/run/secrets/vpn_env"
      ];

      ports = [
        "8000:8000"   # gluetun control server
        "8888:8888"   # gluetun HTTP proxy
        "8388:8388"   # gluetun Shadowsocks
        "9091:9091"   # Transmission
        "7878:7878"   # Radarr
        "8989:8989"   # Sonarr
        "9696:9696"   # Prowlarr
        "8686:8686"   # Lidarr
      ];
    };

    transmission = {
      image = "lscr.io/linuxserver/transmission:latest@sha256:d2183a00bbd5dbb083b14dcd65419379bfd91e0965b52849642354ec3d246452";
      autoStart = true;
      dependsOn = [ "gluetun" ];
      extraOptions = [ "--network=container:gluetun" ];
      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Los_Angeles";
      };
      volumes = [
        "/var/lib/transmission/config:/config"
        "/var/lib/media/torrents:/downloads"
      ];
    };

    radarr = {
      image = "lscr.io/linuxserver/radarr:latest@sha256:a360633a3682d41e96f71a07ff36ecbdf2394a9628465b84b0a8437087715b41";
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
      image = "lscr.io/linuxserver/sonarr:latest@sha256:37be832b78548e3f55f69c45b50e3b14d18df1b6def2a4994258217e67efb1a1";
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
      image = "lscr.io/linuxserver/prowlarr:latest@sha256:a8fe7b9c502f979146b6d0f22438b825c38e068241bb8a708c473062dffdbb03";
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

    lidarr = {
      image = "lscr.io/linuxserver/lidarr:latest@sha256:58f149df604246d7039a4c8b99ab1fefd1c4ae625048c76f3b956f2e0fb9774b";
      autoStart = true;
      dependsOn = [ "gluetun" ];
      extraOptions = [ "--network=container:gluetun" ];
      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Los_Angeles";
      };
      volumes = [
        "/var/lib/lidarr/config:/config"
        "/var/lib/media/music:/music"
        "/var/lib/media/torrents:/downloads"
      ];
    };

    recyclarr = {
      image = "ghcr.io/recyclarr/recyclarr:latest@sha256:55afe316d3e4e4e3b9120cef7c79436b1b5311f6a18d4ef4b7653e720499c90a";
      autoStart = true;
      dependsOn = [ "gluetun" "radarr" "sonarr" ];
      extraOptions = [ "--network=container:gluetun" ];
      environment = {
        TZ = "America/Los_Angeles";
      };
      volumes = [
        "/var/lib/recyclarr/config:/config"
      ];
    };

    portainer-agent = {
      image = "portainer/agent:latest@sha256:e3a9bcb1e5862edaca62d6e54f70efc5815dff33e955a30578b174423b19977c";
      autoStart = true;
      volumes = [
        "/run/podman/podman.sock:/var/run/docker.sock"
        "/var/lib/containers/volumes:/var/lib/docker/volumes"
      ];
      ports = [
        "9001:9001"
      ];
    };

    jellyfin = {
      image = "ghcr.io/linuxserver/jellyfin:latest@sha256:de2f9ee14391f9343ab4d7cbd76ac853a963e226be85fa2366ff144f45fab353";
      autoStart = true;
      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Los_Angeles";
      };
      ports = [
        "8096:8096"
      ];
      volumes = [
        "/var/lib/jellyfin/config:/config"
        "/var/lib/media/movies:/movies"
        "/var/lib/media/tv:/tv"
        "/var/lib/media/music:/music"
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

    PORT_FILE="/var/lib/gluetun/tmp/forwarded_port"

    if [ ! -f "$PORT_FILE" ]; then
      echo "Port file not found yet, waiting..."
      sleep 30
      exit 1
    fi

    PORT=$(cat "$PORT_FILE" | tr -d '[:space:]')

    if [ -z "$PORT" ] || [ "$PORT" = "0" ]; then
      echo "No forwarded port available yet, waiting..."
      sleep 30
      exit 1
    fi

    echo "Forwarded port: $PORT"

    SESSION_ID=$(${pkgs.curl}/bin/curl -si \
      -u "$TRANSMISSION_USERNAME:$TRANSMISSION_PASSWORD" \
      http://localhost:9091/transmission/rpc \
      | ${pkgs.gnugrep}/bin/grep "^X-Transmission-Session-Id:" \
      | ${pkgs.gawk}/bin/awk '{print $2}' \
      | tr -d '\r')

    echo "Session ID: $SESSION_ID"

    ${pkgs.curl}/bin/curl -sf \
      -u "$TRANSMISSION_USERNAME:$TRANSMISSION_PASSWORD" \
      -H "X-Transmission-Session-Id: $SESSION_ID" \
      -d '{"method":"session-set","arguments":{"peer-port":'"$PORT"'}}' \
      http://localhost:9091/transmission/rpc

    echo "Updated Transmission peer port to $PORT"
    sleep 300
  '';
};

systemd.services.podman-gluetun = {
  postStart = ''
    sleep 5
    ${pkgs.iproute2}/bin/ip link set tun0 mtu 1280 2>/dev/null || true
    ${pkgs.ethtool}/bin/ethtool -K tun0 gso off gro off 2>/dev/null || true
  '';
};

  systemd.tmpfiles.rules = [
    "d /var/lib/transmission/config 0755 brian users -"
    "d /var/lib/radarr/config 0755 brian users -"
    "d /var/lib/sonarr/config 0755 brian users -"
    "d /var/lib/prowlarr/config 0755 brian users -"
    "d /var/lib/media/torrents 0755 brian users -"
    "d /var/lib/media/movies 0755 brian users -"
    "d /var/lib/media/tv 0755 brian users -"
    "d /var/lib/gluetun/auth 0755 brian users -"
    "d /var/lib/gluetun/tmp 0755 brian users -"
    "d /var/lib/media/torrents/complete/radarr 0755 brian users -"
    "d /var/lib/media/torrents/complete/sonarr 0755 brian users -"   
    "f /var/lib/gluetun/auth/config.toml 0644 brian users -"
    "d /var/lib/lidarr/config 0755 brian users -"
    "d /var/lib/recyclarr/config 0755 brian users -"
    "d /var/lib/media/music 0755 brian users -"
    "d /var/lib/jellyfin/config 0755 brian users -"
  ];
}
