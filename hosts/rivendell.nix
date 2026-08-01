# hosts/rivendell.nix — host-specific configuration.
#
# rivendell: Raspberry Pi 5, 8GB RAM
# Role: Home Assistant, Matter Server, Caddy (reverse proxy),
#       Blocky + Unbound (secondary DNS), NUT (UPS), Glances

{ config, pkgs, lib, inputs, ... }:

{
  imports = [ (import ../lib/homelab.nix "github-runner-rivendell") ];

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

  # Static ULA for stable IPv6 service addressing, independent of the
  # ISP-delegated (Comcast) GUA prefix, which can rotate without notice.
  # Clients reach Blocky here over IPv6: the UDM Pro advertises this same /64
  # to the LAN and publishes ::8 (mirkwood) / ::9 (rivendell) as the IPv6 DNS
  # servers via RDNSS. SLAAC GUAs still apply for outbound v6 — this only adds
  # a stable, advertisable resolver address. Blocky binds dual-stack (*:53).
  networking.interfaces.eth0.ipv6.addresses = [{
    address = "fd0a:7e1:5e:1::9";
    prefixLength = 64;
  }];

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
      github_runner_token = {
        owner = "github-runner-rivendell";
      };
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

    # Matter fabric. Back to the container path — services.matter-server was
    # reverted (see modules/homeassistant.nix). If the native module is ever
    # re-enabled this MUST become /var/lib/private/matter-server: that module
    # uses DynamicUser=true, so systemd keeps the real state directory under
    # /var/lib/private and leaves a symlink at the unprefixed path, and restic
    # archives a symlink as a symlink — backing up the unprefixed path would
    # capture a link and none of the fabric, discovered only at restore time.
    "/var/lib/matter-server/data"

    # Thread dataset. otbr-agent runs as root (no DynamicUser), so
    # StateDirectory=thread is a real directory and needs no private/ prefix.
    "/var/lib/thread"

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

  # ---------------------------------------------------------------------------
  # GitHub Actions self-hosted runner — aarch64 pre-build for flake updates
  #
  # Builds all Pi closures natively when Renovate opens a flake.lock PR.
  # The nix-daemon's post-build hook pushes results to attic automatically,
  # so deploys that follow get cache hits instead of recompiling.
  #
  # ---------------------------------------------------------------------------
  services.github-runners.rivendell = {
    enable = true;
    url = "https://github.com/bcrescimanno/homelab-nix";
    tokenFile = config.sops.secrets.github_runner_token.path;
    name = "rivendell";
    extraLabels = [ "nix-builder" ];
    replace = true;
    user = "github-runner-rivendell";
    extraPackages = with pkgs; [ nix git openssh ];
    # No `package` override needed: Node 20 reached EOL and was removed from
    # nixpkgs, so github-runner now defaults to nodeRuntimes = [ "node24" ].
  };

  # ---------------------------------------------------------------------------
  # Build resource limits — rivendell is NOT a dedicated builder
  #
  # This host serves Caddy (all *.theshire.io TLS), Home Assistant, secondary
  # DNS, ntfy and Gatus while also acting as the aarch64 CI runner. On
  # 2026-07-31 a pre-build run took the whole host down: base.nix sets
  # max-jobs = 4, so four concurrent Go compiles (the Caddy cloudflare-dns
  # plugin peaks at ~2.2GB RSS each) exhausted 8GB of RAM *and* the 4GB zram
  # swap. zram stores compressed pages in RAM, so filling it consumed the very
  # memory it was meant to relieve. Result: load average 58, ~9MB available,
  # kernel still answering ICMP but no userspace process able to make progress
  # — Caddy, DNS and even sshd wedged. Recovery required a power cycle.
  #
  # NB: builds run as children of nix-daemon, NOT inside the github-runner
  # cgroup, so limiting the runner service alone would have no effect. The
  # limits have to land on nix-daemon.
  # ---------------------------------------------------------------------------

  # Serialise builds and leave CPU for the services this host actually exists
  # to run. Overrides base.nix's max-jobs = 4.
  nix.settings.max-jobs = lib.mkForce 1;
  nix.settings.cores = 2;

  # Builds yield to interactive/service workloads.
  nix.daemonCPUSchedPolicy = "idle";
  nix.daemonIOSchedClass = "idle";

  # Hard backstop: a runaway build gets OOM-killed inside this cgroup instead
  # of taking the host with it. A failed build is recoverable; a wedged
  # rivendell needs physical access.
  systemd.services.nix-daemon.serviceConfig = {
    MemoryHigh = "3G";
    MemoryMax = "4G";
  };
}
