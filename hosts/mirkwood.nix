# hosts/mirkwood.nix — host-specific configuration.
#
# mirkwood: Raspberry Pi 5, 4GB RAM
# Role: Blocky + Unbound (primary DNS), Homepage dashboard,
#       Prometheus + Grafana, Glances

{ config, pkgs, lib, inputs, ... }:

{
  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------

  networking.hostName = "mirkwood";

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

  # Unbound requests a 4MB UDP send/receive buffer but the default kernel max
  # is ~425KB, causing "so-sndbuf was not granted" warnings at startup.
  # Under high query load this can cause silent UDP packet drops.
  boot.kernel.sysctl = {
    "net.core.rmem_max" = 4194304;
    "net.core.wmem_max" = 4194304;
  };

  # ---------------------------------------------------------------------------
  # System state version
  # ---------------------------------------------------------------------------

  system.stateVersion = "25.11";

  # ---------------------------------------------------------------------------
  # SOPS Secrets
  # ---------------------------------------------------------------------------

  sops = {
    defaultSopsFile = ../secrets/mirkwood.yaml;
    defaultSopsFormat = "yaml";
    age.keyFile = "/var/lib/sops-nix/key.txt";

    secrets = {
      # JWT push token for the attic post-build hook (mirkwood builds push to
      # orthanc-hosted cache). See modules/attic.nix for setup instructions.
      attic_push_token = {};
    };
  };

  home-manager.users.brian = {
    imports = [ "${inputs.dotfiles}/machines/mirkwood.nix" ];
  };

  # ---------------------------------------------------------------------------
  # Backup
  # ---------------------------------------------------------------------------
  homelab.backup.paths = [
    "/var/lib/grafana"
  ];
}
