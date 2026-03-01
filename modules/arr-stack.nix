# modules/arr-stack.nix — the arr stack running behind a VPN.
#
# This module defines the full arr stack: gluetun (VPN), qBittorrent,
# Sonarr, Radarr, and Prowlarr. All torrent traffic is routed through
# the gluetun container. The arr apps communicate with qBittorrent
# inside the shared network namespace.
#
# HOW THE VPN NETWORK SHARING WORKS:
#
# The key pattern is that qBittorrent and the arr apps declare:
#   dependsOn = [ "gluetun" ];
#   extraOptions = [ "--network=container:gluetun" ];
#
# This means those containers share gluetun's network namespace — they
# literally use the same network stack as gluetun. All their traffic
# exits through the VPN tunnel. If the VPN drops, the network namespace
# disappears and those containers lose connectivity, which is the
# kill-switch behavior you want.
#
# The web UIs are still accessible from your LAN because gluetun exposes
# those ports on your Pi's real IP, and the containers share that namespace.
#
# WHY THIS WORKS BETTER WITH PODMAN THAN DOCKER ON RASPBERRY PI OS:
#
# Docker on Debian/Raspberry Pi OS aggressively manages iptables rules.
# When it sets up its network bridge, it adds rules that can interfere
# with the VPN tunnel's routing. Specifically, Docker's FORWARD chain
# rules and its NAT masquerade rules can break the routing table that
# the VPN client sets up inside the container.
#
# Podman uses a different networking stack (netavark/aardvark-dns) and
# for rootless containers uses slirp4netns, which doesn't touch the
# host's iptables at all. This sidesteps the conflict entirely.
# On NixOS, even rootful Podman behaves more predictably because NixOS
# manages firewall rules declaratively and Podman doesn't fight it.

{ config, pkgs, lib, ... }:

{
  # We need to ensure the /config directories exist with correct ownership.
  # systemd-tmpfiles is NixOS's way of declaring that certain paths should
  # exist at boot with certain permissions — analogous to what you'd normally
  # do with `mkdir -p` in a setup script.
  systemd.tmpfiles.rules = [
    "d /config/gluetun      0750 alice users -"
    "d /config/qbittorrent  0750 alice users -"
    "d /config/sonarr       0750 alice users -"
    "d /config/radarr       0750 alice users -"
    "d /config/prowlarr     0750 alice users -"
    "d /media/downloads     0750 alice users -"
    "d /media/tv            0750 alice users -"
    "d /media/movies        0750 alice users -"
  ];

  # ---------------------------------------------------------------------------
  # Container definitions via virtualisation.oci-containers
  # ---------------------------------------------------------------------------
  #
  # NixOS's oci-containers module generates a systemd service for each
  # container. The service is named `podman-<name>.service`. NixOS handles
  # starting, stopping, and restart policies automatically.
  #
  # Setting `backend = "podman"` here applies to all containers in this
  # module. You could also set this in base.nix to make it global.

  virtualisation.oci-containers.backend = "podman";

  virtualisation.oci-containers.containers = {

    # -------------------------------------------------------------------------
    # Gluetun — VPN gateway container
    # -------------------------------------------------------------------------
    # All other containers in this stack route their traffic through this one.
    # Gluetun supports most major VPN providers (Mullvad, ProtonVPN, etc).
    # You configure it via environment variables — provider-specific docs are
    # at https://github.com/qdm12/gluetun/wiki

    gluetun = {
      image = "ghcr.io/qdm12/gluetun:latest";

      # These ports are published on the Pi's real IP. Even though qBittorrent
      # and the arr apps run inside gluetun's network namespace, their web UIs
      # are accessible because gluetun forwards these ports.
      ports = [
        "8080:8080"   # qBittorrent web UI
        "8989:8989"   # Sonarr
        "7878:7878"   # Radarr
        "9696:9696"   # Prowlarr
      ];

      volumes = [ "/config/gluetun:/gluetun" ];

      environment = {
        VPN_SERVICE_PROVIDER = "mullvad"; # change to your provider
        VPN_TYPE = "wireguard";           # or openvpn
        # Provider-specific vars go here. For Mullvad + WireGuard:
        # WIREGUARD_PRIVATE_KEY = "...";
        # SERVER_COUNTRIES = "Netherlands";
        # These are sensitive — see the note below about secrets.
        FIREWALL_OUTBOUND_SUBNETS = "192.168.1.0/24"; # allow LAN traffic
      };

      # /dev/net/tun is the kernel TUN device — required for VPN tunnels.
      # Podman exposes this cleanly without the iptables conflicts Docker has.
      extraOptions = [
        "--cap-add=NET_ADMIN"
        "--device=/dev/net/tun"
        "--sysctl=net.ipv6.conf.all.disable_ipv6=1"
      ];
    };

    # -------------------------------------------------------------------------
    # qBittorrent — torrent client
    # -------------------------------------------------------------------------

    qbittorrent = {
      image = "lscr.io/linuxserver/qbittorrent:latest";

      # No `ports` here — qBittorrent's port (8080) is published by gluetun above.
      # Because this container shares gluetun's network namespace, it can
      # bind to 8080 and gluetun will forward it.

      volumes = [
        "/config/qbittorrent:/config"
        "/media/downloads:/downloads"
      ];

      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Chicago";
        WEBUI_PORT = "8080";
      };

      dependsOn = [ "gluetun" ];

      # This is the critical line: share gluetun's network namespace.
      extraOptions = [ "--network=container:gluetun" ];
    };

    # -------------------------------------------------------------------------
    # Sonarr — TV show management
    # -------------------------------------------------------------------------

    sonarr = {
      image = "lscr.io/linuxserver/sonarr:latest";

      volumes = [
        "/config/sonarr:/config"
        "/media/tv:/tv"
        "/media/downloads:/downloads"
      ];

      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Chicago";
      };

      dependsOn = [ "gluetun" ];
      extraOptions = [ "--network=container:gluetun" ];
    };

    # -------------------------------------------------------------------------
    # Radarr — movie management
    # -------------------------------------------------------------------------

    radarr = {
      image = "lscr.io/linuxserver/radarr:latest";

      volumes = [
        "/config/radarr:/config"
        "/media/movies:/movies"
        "/media/downloads:/downloads"
      ];

      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Chicago";
      };

      dependsOn = [ "gluetun" ];
      extraOptions = [ "--network=container:gluetun" ];
    };

    # -------------------------------------------------------------------------
    # Prowlarr — indexer management (connects to Sonarr + Radarr)
    # -------------------------------------------------------------------------

    prowlarr = {
      image = "lscr.io/linuxserver/prowlarr:latest";

      volumes = [
        "/config/prowlarr:/config"
      ];

      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Chicago";
      };

      dependsOn = [ "gluetun" ];
      extraOptions = [ "--network=container:gluetun" ];
    };

  };

  # ---------------------------------------------------------------------------
  # A NOTE ON SECRETS
  # ---------------------------------------------------------------------------
  #
  # You'll notice VPN credentials above are placeholders. You should NEVER
  # commit real credentials in your Nix files — they'd be in your git history
  # forever and would end up world-readable in /nix/store.
  #
  # The idiomatic NixOS solution is `agenix` or `sops-nix`. Both let you
  # commit encrypted secrets to git and have NixOS decrypt them at boot
  # using a key that lives only on the device (typically derived from its
  # SSH host key). This is worth setting up before you go live.
  #
  # With sops-nix, your secret would look like:
  #
  #   sops.secrets.wireguard_private_key = {};
  #
  # And then in the container definition:
  #
  #   environmentFiles = [ config.sops.secrets.wireguard_private_key.path ];
  #
  # The environmentFiles option reads a file containing KEY=VALUE pairs
  # and injects them as environment variables at container start time,
  # without ever writing them to the Nix store.
}
