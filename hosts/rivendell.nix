# hosts/rivendell.nix — host-specific configuration.
#
# rivendell: Raspberry Pi 5, 8GB RAM
# Role: Home Assistant, Matter Server, Caddy (reverse proxy),
#       Technitium (secondary DNS), NUT (UPS), Glances

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
      technitium_env = {};
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
    "/var/lib/caddy"
    "/var/lib/technitium/config"
    "/var/lib/uptime-kuma"
  ];
}
