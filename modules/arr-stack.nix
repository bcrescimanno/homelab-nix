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

      environment = {
        VPN_SERVICE_PROVIDER = "protonvpn";
        VPN_TYPE = "wireguard";
        # Server endpoint hostname only — port comes from the secret
        SERVER_COUNTRIES = "United States";
        VPN_PORT_FORWARDING = "on";
      };

      extraOptions = [
        "--cap-add=NET_ADMIN"
        "--device=/dev/net/tun:/dev/net/tun"
        "--env-file=/run/secrets/vpn_env"
      ];

      ports = [
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

  systemd.tmpfiles.rules = [
    "d /var/lib/qbittorrent/config 0755 brian users -"
    "d /var/lib/radarr/config 0755 brian users -"
    "d /var/lib/sonarr/config 0755 brian users -"
    "d /var/lib/prowlarr/config 0755 brian users -"
    "d /var/lib/media/torrents 0755 brian users -"
    "d /var/lib/media/movies 0755 brian users -"
    "d /var/lib/media/tv 0755 brian users -"
  ];
}
