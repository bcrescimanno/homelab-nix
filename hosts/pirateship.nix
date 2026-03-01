# hosts/pi-media.nix — host-specific configuration.
#
# This file contains things that are unique to this particular machine:
# its hostname, the disk it boots from, its IP address, and any
# hardware-specific overrides. Everything generic lives in modules/.
#
# The `{ config, pkgs, lib, ... }:` at the top is a function signature.
# NixOS passes these arguments to every module automatically. You use
# `pkgs` to reference packages, `lib` for helper functions, and `config`
# to read values set by other modules (useful for conditional logic).

{ config, pkgs, lib, ... }:

{
  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------

  networking.hostName = "pi-media";

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
            type = "EF00"; # EFI System Partition
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
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

  # Tell the bootloader to use the EFI partition we defined above.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ---------------------------------------------------------------------------
  # Networking
  # ---------------------------------------------------------------------------

  # A static IP makes the Pi easier to reach and avoids depending on DHCP
  # leases staying consistent. Adjust to match your home network.
  networking.interfaces.eth0.ipv4.addresses = [{
    address = "192.168.1.50";
    prefixLength = 24;
  }];
  networking.defaultGateway = "192.168.1.1";
  networking.nameservers = [ "192.168.1.2" ]; # Pointing at your pi-hole

  # ---------------------------------------------------------------------------
  # Storage mounts
  # ---------------------------------------------------------------------------

  # If you have a USB HDD or a second drive for media, declare it here.
  # NixOS will ensure it's mounted on boot. The device path and fsType
  # depend on your actual hardware.
  fileSystems."/media" = {
    device = "/dev/disk/by-label/MEDIA"; # Using a disk label is more robust
    fsType = "ext4";                      # than /dev/sdX which can change
    options = [ "defaults" "nofail" ];    # nofail: boot even if drive is absent
  };

  # ---------------------------------------------------------------------------
  # System state version
  # ---------------------------------------------------------------------------

  # This should match the NixOS release you initially installed with.
  # It controls behavior of certain migration scripts. Don't change it
  # after the fact — it's not a "target version" setting.
  system.stateVersion = "24.05";
}
