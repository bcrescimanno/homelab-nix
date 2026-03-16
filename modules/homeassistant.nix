# modules/homeassistant.nix — Home Assistant + Matter Server
#
# Home Assistant: home automation platform (port 8123)
# Matter Server: bridges Matter-protocol IoT devices into HA
#
# Both containers use host networking — required for mDNS/Zeroconf
# device discovery and Matter commissioning to work correctly.
# With host networking, HA and Matter Server communicate via localhost
# (Matter Server WebSocket on port 5580 is not exposed externally).
#
# --privileged is used for full hardware access: USB dongles (Zigbee,
# Z-Wave), Bluetooth (Matter commissioning), and multicast networking.
# If a USB device is plugged in (e.g., a Zigbee coordinator), it will
# be accessible inside the HA container automatically.

{ config, pkgs, lib, ... }:

{
  virtualisation.oci-containers.containers = {

    homeassistant = {
      image = "ghcr.io/home-assistant/home-assistant:stable@sha256:572a5d030f652e9ef6c6d4f6631169af83eb3b739c9b4b3965669f5e9d9f3858";
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

  };

  # Enable Bluetooth userspace daemon (bluetoothd) so HA and Matter Server
  # can access the Pi 5's built-in Bluetooth adapter via DBus.
  hardware.bluetooth.enable = true;

  # Port 5580 (Matter Server WebSocket) is localhost-only — HA connects
  # to it internally and it does not need to be reachable from the network.
  # UDP 4001: Govee Local — devices send status updates to this port on the host.
  networking.firewall.allowedTCPPorts = [ 8123 ];
  networking.firewall.allowedUDPPorts = [ 4001 ];

  systemd.tmpfiles.rules = [
    "d /var/lib/homeassistant/config 0755 root root -"
    "d /var/lib/matter-server/data 0755 root root -"
  ];
}
