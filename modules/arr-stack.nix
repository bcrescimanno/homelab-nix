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
      };

      environmentFiles = [
        config.sops.secrets.vpn_env.path
      ];

      extraOptions = [
        "--cap-add=NET_ADMIN"
        "--device=/dev/net/tun:/dev/net/tun"
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

  };
}
