# modules/arr-stack.nix — VPN-connected container stack
#
# All arr containers share gluetun's network namespace. If the VPN
# drops, all containers lose connectivity — this is the kill switch.

{ config, pkgs, lib, ... }:

let
  recyclarrConfig = pkgs.writeText "recyclarr.yml" ''
    sonarr:
      sonarr-main:
        base_url: http://localhost:8989
        api_key: !env_var SONARR_API_KEY
        delete_old_custom_formats: true
        quality_definition:
          type: series
        quality_profiles:
          - trash_id: 72dae194fc92bf828f32cde7744e51a1 # WEB-1080p
            reset_unmatched_scores:
              enabled: true
          - trash_id: d1498e7d189fbe6c7110ceaabb7473e6 # WEB-2160p
            reset_unmatched_scores:
              enabled: true

    radarr:
      radarr-main:
        base_url: http://localhost:7878
        api_key: !env_var RADARR_API_KEY
        delete_old_custom_formats: true
        quality_definition:
          type: movie
        quality_profiles:
          - trash_id: 64fb5f9858489bdac2af690e27c8f42f # UHD Bluray + WEB
            reset_unmatched_scores:
              enabled: true
  '';
in

{
  virtualisation.oci-containers.containers = {

    gluetun = {
      image = "ghcr.io/qdm12/gluetun:latest@sha256:bcbfa88ddb5191fa0cc067115583672028fdd0e6b551d66fc5d00b26ff0d8e11";
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
        "8080:8080"   # SABnzbd
      ];
    };

    transmission = {
      image = "lscr.io/linuxserver/transmission:latest@sha256:25e04da44850ac03f93c9a2cfc4275c67ff0973e49eca48b459b06e0b45d7b82";
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
      image = "lscr.io/linuxserver/radarr:latest@sha256:ca43905eaf2dd11425efdcfe184892e43806b1ae0a830440c825cecbc2629cfb";
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
        "/var/lib/media/usenet:/sabnzbd"
      ];
    };

    sonarr = {
      image = "lscr.io/linuxserver/sonarr:latest@sha256:21c1c3d52248589bb064f5adafec18cad45812d7a01d317472955eef051e619b";
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
        "/var/lib/media/usenet:/sabnzbd"
      ];
    };

    prowlarr = {
      image = "lscr.io/linuxserver/prowlarr:latest@sha256:9ef5d8bf832edcacb6082f9262cb36087854e78eb7b1c3e1d4375056055b2d82";
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
      image = "lscr.io/linuxserver/lidarr:latest@sha256:dbffcf91da47d48e09e613857032c95a62755b928a71a7718688e3ab03fbbd26";
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
        "/var/lib/media/usenet:/sabnzbd"
      ];
    };

    recyclarr = {
      image = "ghcr.io/recyclarr/recyclarr:latest@sha256:55afe316d3e4e4e3b9120cef7c79436b1b5311f6a18d4ef4b7653e720499c90a";
      autoStart = true;
      dependsOn = [ "gluetun" "radarr" "sonarr" ];
      extraOptions = [
        "--network=container:gluetun"
        "--env-file=${config.sops.secrets.recyclarr_env.path}"
      ];
      environment = {
        TZ = "America/Los_Angeles";
      };
      volumes = [
        "/var/lib/recyclarr/config:/config"
        "${recyclarrConfig}:/config/recyclarr.yml:ro"
      ];
    };

    sabnzbd = {
      image = "lscr.io/linuxserver/sabnzbd:latest@sha256:9b6662d5871518346655bfd3acb4c94e11f31c79c103ef04154558dab927c852";
      autoStart = true;
      dependsOn = [ "gluetun" ];
      extraOptions = [ "--network=container:gluetun" ];
      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Los_Angeles";
      };
      volumes = [
        "/var/lib/sabnzbd/config:/config"
        "/var/lib/media/usenet:/sabnzbd"
      ];
    };

    jellyfin = {
      image = "ghcr.io/linuxserver/jellyfin:latest@sha256:aae645d1ff11c42b1d2d3b80694e34e0e1ea4a51879900843c8ab6e8b127a32a";
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

  systemd.services.transmission-port-sync = {
  description = "Sync gluetun forwarded port to Transmission";
  after = [ "podman-gluetun.service" "podman-transmission.service" ];
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
    "d /var/lib/media/torrents/complete/lidarr 0755 brian users -"   
    "f /var/lib/gluetun/auth/config.toml 0644 brian users -"
    "d /var/lib/lidarr/config 0755 brian users -"
    "d /var/lib/recyclarr/config 0755 brian users -"
    "d /var/lib/media/music 0755 brian users -"
    "d /var/lib/jellyfin/config 0755 brian users -"
    "d /var/lib/sabnzbd/config 0755 brian users -"
    "d /var/lib/media/usenet 0755 brian users -"
    "d /var/lib/media/usenet/incomplete 0755 brian users -"
    "d /var/lib/media/usenet/complete 0755 brian users -"
  ];

  sops.secrets.recyclarr_env = {};
}
