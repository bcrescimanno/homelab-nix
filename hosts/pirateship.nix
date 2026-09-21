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
      # Shared credential the NUT secondary uses to authenticate to rivendell's
      # upsd (modules/nut-secondary.nix). Must hold the same value as
      # nut_secondary_password in secrets/rivendell.yaml, which defines the
      # matching upsd user. Default 0400 root:root is correct — systemd reads it
      # via LoadCredential as root before upsmon drops privileges.
      nut_secondary_password = {};
      # JWT push token for the attic post-build hook — provisioned in phase 2.
      # See step 5-6 in modules/attic.nix for setup instructions.
      attic_push_token = {};
    };
  };

  home-manager.users.brian = {
    imports = [ "${inputs.dotfiles}/machines/pirateship.nix" ];
  };

  # ---------------------------------------------------------------------------
  # Backup
  # ---------------------------------------------------------------------------
  # ---------------------------------------------------------------------------
  # UPS load shedding
  # ---------------------------------------------------------------------------
  #
  # NOT for power: this Pi draws ~1.9 W on its internal rails, so shedding it
  # saves nothing measurable (see Plan.md → Measured power report). It sheds so
  # that **erebor can be powered off cleanly**.
  #
  # pirateship holds a `hard` NFS mount of erebor's whole media share for the arr
  # stack and Navidrome. If erebor went down first, every IO here would block
  # forever in D state, this host would then fail to unmount at FSD, stall past
  # systemd's timeout and take the unclean cut the NUT work exists to prevent.
  #
  # 35% is above rivendell's 25% erebor trigger so this host is already gone by
  # then; rivendell's `waitForDown` verifies it rather than assuming. No charge
  # floor and no early time trigger — there is no power reason to go sooner, and
  # the media stack may as well run while the battery lasts.
  homelab.ups.shedBelowCharge = 35;

  homelab.backup.paths = [
    "/var/lib/qbittorrent/config"
    "/var/lib/radarr/config"
    "/var/lib/sonarr/config"
    "/var/lib/prowlarr/config"
    "/var/lib/lidarr/config"
    "/var/lib/sabnzbd/config"

    # NO jellyfin path here. Jellyfin moved to orthanc (native, modules/jellyfin.nix)
    # on 2026-04-03 and its state is backed up there as /var/lib/jellyfin. The
    # container-era directory was left behind on this host and kept being
    # archived to BOTH repos nightly — 530MB and ~5,000 entries of data last
    # written the day of the migration. Removed 2026-09-20; the stale directory
    # was deleted from the host at the same time.
    "/var/lib/bazarr"
    "/var/lib/navidrome"   # music library DB + user accounts/playlists
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
