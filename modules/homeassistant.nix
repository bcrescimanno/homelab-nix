# modules/homeassistant.nix — Home Assistant + Matter Server + OTBR
#
# Home Assistant: home automation platform (port 8123)
# Matter Server: bridges Matter-protocol IoT devices into HA
# OTBR (OpenThread Border Router): Thread border router via ZBT-2 USB dongle
#
# All containers use host networking — required for mDNS/Zeroconf
# device discovery and Matter/Thread commissioning to work correctly.
# With host networking, HA and Matter Server communicate via localhost
# (Matter Server WebSocket on port 5580 is not exposed externally).
# OTBR REST API on port 8086 is accessed by HA's Thread integration via localhost.
#
# --privileged is used for full hardware access: USB dongles (Zigbee,
# Z-Wave, Thread/ZBT-2), Bluetooth (Matter commissioning), and multicast
# networking. Any USB device plugged in will be accessible inside the
# container automatically.
#
# ZBT-2 (Nabu Casa, 303a:831a) presents as /dev/ttyACM0 in Thread RCP mode.
# If running Multi-PAN firmware (Zigbee + Thread concurrently), a cpcd
# container would be required between the USB device and OTBR.

{ config, pkgs, lib, ... }:

{
  virtualisation.oci-containers.containers = {

    homeassistant = {
      image = "ghcr.io/home-assistant/home-assistant:stable@sha256:ae0800c81fea16bc1241ce03bddb9c6260566e90f58b09d3e5a629e4f68bdc0b";
      autoStart = true;
      volumes = [
        "/var/lib/homeassistant/config:/config"
        "/run/dbus:/run/dbus:ro"
      ];
      environment = {
        TZ = "America/Los_Angeles";
      };
      extraOptions = [
        "--network=host"
        "--privileged"
      ];
    };

    matter-server = {
      image = "ghcr.io/home-assistant-libs/python-matter-server:stable@sha256:170aa093ce91c76cde4cc390918307590f0f5558fcec93f913af3cb019e6562a";
      autoStart = true;
      # --primary-interface eth0: bind mDNS/multicast to the Ethernet interface
      # so Matter Server can discover WiFi devices on the local network.
      # Without this it defaults to 'None' and mDNS discovery fails.
      cmd = [ "--storage-path" "/data" "--primary-interface" "eth0" ];
      volumes = [
        "/var/lib/matter-server/data:/data"
        # DBus access is required for Bluetooth (Matter commissioning).
        "/run/dbus:/run/dbus:ro"
      ];
      extraOptions = [
        "--network=host"
        "--privileged"
      ];
    };

    # OpenThread Border Router — Thread border router for HA's Thread integration.
    # ZBT-2 USB dongle (/dev/ttyACM0) acts as the Thread radio (RCP mode).
    # HA Thread integration URL: http://localhost:8081
    #
    # The REST API binds to 127.0.0.1:8081 by default in this image version.
    # HA reaches it via localhost (both share host networking). No LAN exposure.
    #
    # NAT64/NAT44 disabled (NAT64=0, DOCKER=0):
    #   The openthread/otbr image defaults NAT64=1 and DOCKER=1, which causes
    #   the startup script to configure NAT via iptables-legacy. NixOS uses
    #   nftables and does not load the ip_tables kernel modules, so iptables
    #   fails with "Table does not exist" and the container exits.
    #
    #   For our use case — HA local control over Thread — NAT64 is not needed.
    #   Thread devices communicate with HA directly over the mesh; they do not
    #   need to reach IPv4 internet resources through the border router.
    #
    #   If internet-connected Thread devices are ever needed (e.g., devices that
    #   phone home to IPv4 cloud services via the border router), re-enable NAT64
    #   by removing the NAT64/DOCKER env vars and loading the required iptables
    #   kernel modules in NixOS instead:
    #
    #     boot.kernelModules = [
    #       "ip_tables" "iptable_filter" "iptable_nat" "iptable_mangle"
    #       "ip6_tables" "ip6table_filter" "ip6table_nat"
    #     ];
    #
    #   With those modules loaded, iptables-legacy inside the container can
    #   coexist with the host's nftables firewall.
    otbr = {
      image = "openthread/otbr:latest@sha256:8f1c3e7d5571f585d95e8556bfb348e2eb480bc929b1863797467c9e7e709bc8";
      autoStart = true;
      cmd = [
        "--radio-url" "spinel+hdlc+uart:///dev/ttyACM0?uart-baudrate=460800"
        "--backbone-interface" "eth0"
      ];
      environment = {
        NAT64 = "0";
        DOCKER = "0";
      };
      volumes = [
        "/var/lib/otbr/data:/var/lib/thread"
      ];
      extraOptions = [
        "--network=host"
        "--privileged"
      ];
    };

  };

  # Enable Bluetooth userspace daemon (bluetoothd) so HA and Matter Server
  # can access the Pi 5's built-in Bluetooth adapter via DBus.
  hardware.bluetooth.enable = true;

  # Port 5580 (Matter Server WebSocket) is localhost-only — HA connects
  # to it internally and it does not need to be reachable from the network.
  # UDP 4001: Govee Local — devices send status updates to this port on the host.
  # OTBR REST API (8081) is localhost-only — HA connects via localhost, no LAN
  # exposure needed or possible (bound to 127.0.0.1 by the container).
  networking.firewall.allowedTCPPorts = [ 8123 ];
  networking.firewall.allowedUDPPorts = [ 4001 ];

  systemd.tmpfiles.rules = [
    "d /var/lib/homeassistant/config 0755 root root -"
    "d /var/lib/matter-server/data 0755 root root -"
    "d /var/lib/otbr/data 0755 root root -"
  ];
}
