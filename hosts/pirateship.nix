# hosts/pirateship.nix — host-specific configuration.
#
# This file contains things that are unique to this particular machine:
# its hostname, the disk it boots from, its IP address, and any
# hardware-specific overrides. Everything generic lives in modules/.
#
# The `{ config, pkgs, lib, ... }:` at the top is a function signature.
# NixOS passes these arguments to every module automatically. You use
# `pkgs` to reference packages, `lib` for helper functions, and `config`
# to read values set by other modules (useful for conditional logic).

{ config, pkgs, lib, inputs, ... }:

{
  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------

  networking.hostName = "pirateship";

  # ---------------------------------------------------------------------------
  # Boot & Disk
  # ---------------------------------------------------------------------------

  # disko will use this declaration to partition and format the NVMe drive
  # during initial installation via nixos-anywhere. After that, NixOS reads
  # it to know where to find its filesystems.
  #
  # This is a simple layout: one EFI partition for the bootloader and one
  # ext4 partition for everything else. You could add a separate /nix/store
  # partition, btrfs with snapshots, etc., but this is a solid starting point.
  disko.devices = {
    disk.nvme = {
      type = "disk";
      # This is the standard NVMe device path on Pi with an NVMe HAT.
      # Confirm with `lsblk` if yours differs.
      device = "/dev/nvme0n1";
      content = {
        type = "gpt";
        partitions = {
          boot = {
            size = "512M";
            type = "EF00"; # FAT32 firmware partition
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

  # This should match the NixOS release you initially installed with.
  # It controls behavior of certain migration scripts. Don't change it
  # after the fact — it's not a "target version" setting.
  system.stateVersion = "25.11";

  # ---------------------------------------------------------------------------
  # SOPS Secrets
  # ---------------------------------------------------------------------------
  sops = {
    defaultSopsFile = ../secrets/pirateship.yaml;
    defaultSopsFormat = "yaml";
    age.keyFile = "/var/lib/sops-nix/key.txt";
    
    secrets = {
      vpn_env = {};
      qbt_credentials = {};
    };
  };

  home-manager.users.brian = {
    imports = [ "${inputs.dotfiles}/machines/pirateship.nix" ];
  };

  # ---------------------------------------------------------------------------
  # Backup
  # ---------------------------------------------------------------------------
  homelab.backup.paths = [
    "/var/lib/qbittorrent/config"
    "/var/lib/radarr/config"
    "/var/lib/sonarr/config"
    "/var/lib/prowlarr/config"
    "/var/lib/lidarr/config"
    "/var/lib/sabnzbd/config"
    "/var/lib/jellyfin/config"
    "/var/lib/navidrome"
  ];

  # ---------------------------------------------------------------------------
  # NFS client support
  # ---------------------------------------------------------------------------
  boot.supportedFilesystems = [ "nfs" ];
  services.rpcbind.enable = true;

  # ---------------------------------------------------------------------------
  # NAS mounts (erebor — UniFi UNAS Pro 4, RAID 6 ~24TB)
  #
  # Mounted at the same paths as the old local directories so arr-stack.nix
  # needs no changes. _netdev tells systemd to wait for network; x-systemd.automount
  # mounts on first access so boot doesn't hang if erebor is temporarily unavailable.
  # ---------------------------------------------------------------------------
  fileSystems."/var/lib/media" = {
    device = "erebor.theshire.io:/var/nfs/shared/media";
    fsType = "nfs";
    options = [ "_netdev" "nofail" "x-systemd.automount" "noauto" ];
  };
}
