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
      # JWT push token for the attic post-build hook — provisioned in phase 2.
      # See step 5-6 in modules/attic.nix for setup instructions.
      attic_push_token = {};
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
    "/var/lib/music-assistant"
  ];

  # ---------------------------------------------------------------------------
  # NFS client support
  # ---------------------------------------------------------------------------
  boot.supportedFilesystems = [ "nfs" ];
  services.rpcbind.enable = true;

  # ---------------------------------------------------------------------------
  # NAS mounts (erebor — music library, read-only)
  #
  # Music Assistant reads the library directly from erebor rather than going
  # through Navidrome. Mount is read-only since rivendell never writes media.
  # _netdev + automount ensures boot doesn't hang if erebor is unavailable.
  #
  # Note: the music-assistant service user must be able to read the mounted
  # files. Configure the erebor NFS export with appropriate uid mapping
  # (e.g. all_squash + anonuid/anongid, or world-readable file permissions).
  # ---------------------------------------------------------------------------
  fileSystems."/var/lib/media/music" = {
    device = "erebor.theshire.io:/var/nfs/shared/media/music";
    fsType = "nfs";
    options = [ "_netdev" "nofail" "x-systemd.automount" "noauto" "ro" ];
  };
}
