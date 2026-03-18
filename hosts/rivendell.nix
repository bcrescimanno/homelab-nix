# hosts/rivendell.nix — host-specific configuration.
#
# rivendell: Raspberry Pi 5, 8GB RAM
# Role: Home Assistant, Matter Server, Caddy (reverse proxy),
#       Blocky + Unbound (secondary DNS), NUT (UPS), Glances

{ config, pkgs, lib, inputs, ... }:

{
  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------

  networking.hostName = "rivendell";

  # ---------------------------------------------------------------------------
  # Boot & Disk
  # ---------------------------------------------------------------------------

  # disko will use this declaration to partition and format the NVMe drive
  # during initial installation via nixos-anywhere.
  #
  # Verify the device path with `lsblk` before running nixos-anywhere.
  # NVMe HAT typically presents as /dev/nvme0n1.
  disko.devices = {
    disk.nvme = {
      type = "disk";
      device = "/dev/nvme0n1";
      content = {
        type = "gpt";
        partitions = {
          boot = {
            size = "512M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot/firmware";
            };
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };

  boot.loader.raspberry-pi.bootloader = "kernel";

  # ---------------------------------------------------------------------------
  # Networking
  # ---------------------------------------------------------------------------

  networking.interfaces.eth0.useDHCP = true;

  # VLAN 4 subinterface for IoT network — used exclusively to send Wake-on-LAN
  # broadcasts to IoT VLAN devices from Home Assistant. The switch port is
  # already a trunk ("Allow All" tagged VLANs), so no UniFi changes are needed.
  # HA sends magic packets to 10.0.15.255 (IoT /22 broadcast); the kernel routes
  # them out eth0.4 as a tagged L2 broadcast on VLAN 4. The NixOS firewall
  # default-drops inbound on this interface, so IoT devices cannot reach rivendell.
  networking.vlans."eth0.4" = {
    id = 4;
    interface = "eth0";
  };
  networking.interfaces."eth0.4" = {
    ipv4.addresses = [{
      address = "10.0.12.2";
      prefixLength = 22;
    }];
  };

  # ---------------------------------------------------------------------------
  # System state version
  # ---------------------------------------------------------------------------

  system.stateVersion = "25.11";

  # ---------------------------------------------------------------------------
  # SOPS Secrets
  # ---------------------------------------------------------------------------

  sops = {
    defaultSopsFile = ../secrets/rivendell.yaml;
    defaultSopsFormat = "yaml";
    age.keyFile = "/var/lib/sops-nix/key.txt";

    secrets = {
      nut_upsmon_password = {};
      nut_ha_password = {};
    };
  };

  home-manager.users.brian = {
    imports = [ "${inputs.dotfiles}/machines/rivendell.nix" ];
  };

  # ---------------------------------------------------------------------------
  # Backup
  # ---------------------------------------------------------------------------
  homelab.backup.paths = [
    "/var/lib/homeassistant/config"
    "/var/lib/matter-server/data"
    "/var/lib/otbr/data"
    "/var/lib/caddy"
  ];
}
