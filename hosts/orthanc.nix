# hosts/orthanc.nix — host-specific configuration for orthanc.
#
# orthanc is an x86_64 tower server (Ryzen 9 5950X, 32GB RAM, ASUS X570-E Gaming).
# Roles: Nix builder (GitHub Actions CI), Minecraft game server, Attic binary cache (planned).
#
# Initial installation via nixos-anywhere (headless, no monitor needed):
#   # Prepare the age key directory to upload during install:
#   mkdir -p /tmp/orthanc-extra/var/lib/sops-nix
#   cp /tmp/orthanc-age-key.txt /tmp/orthanc-extra/var/lib/sops-nix/key.txt
#
#   nix run github:nix-community/nixos-anywhere -- \
#     --flake .#orthanc \
#     --extra-files /tmp/orthanc-extra \
#     root@<ip>

{ config, pkgs, lib, inputs, ... }:

{
  imports = [
    (import ../lib/homelab.nix "cloudflared")
    (import ../lib/homelab.nix "github-runner-orthanc")
  ];

  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------

  networking.hostName = "orthanc";

  # ---------------------------------------------------------------------------
  # Boot & Disk
  # ---------------------------------------------------------------------------

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # amd_pstate=active enables the EPP (Energy Performance Preference) driver,
  # which replaces acpi-cpufreq and gives the CPU hardware-level power hints.
  # Required for auto-cpufreq's EPP mode to work on Zen 3.
  boot.kernelParams = [ "amd_pstate=active" ];

  # AMD microcode updates — apply latest CPU microcode on boot.
  hardware.cpu.amd.updateMicrocode = true;

  # ---------------------------------------------------------------------------
  # Power management
  # ---------------------------------------------------------------------------
  #
  # auto-cpufreq dynamically scales the CPU governor and EPP based on system
  # load. On a plugged-in desktop with bursty workloads (remote builds, game
  # server), "powersave" governor + "balance_power" EPP idles efficiently while
  # still boosting for short bursts. "turbo = auto" lets the CPU boost when
  # needed but doesn't hold boost clocks during idle periods.

  services.auto-cpufreq = {
    enable = true;
    settings = {
      charger = {
        governor = "powersave";
        energy_performance_preference = "balance_power";
        turbo = "auto";
      };
    };
  };

  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/nvme0n1"; # Samsung 970 EVO NVMe SSD
      content = {
        type = "gpt";
        partitions = {
          boot = {
            size = "512M";
            type = "EF00"; # EFI system partition
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

  # ---------------------------------------------------------------------------
  # Networking
  # ---------------------------------------------------------------------------

  networking.useDHCP = lib.mkDefault true;

  # ---------------------------------------------------------------------------
  # NFS client support
  # ---------------------------------------------------------------------------
  boot.supportedFilesystems = [ "nfs" ];
  services.rpcbind.enable = true;

  # ---------------------------------------------------------------------------
  # NAS mounts (erebor — UniFi UNAS Pro 4, RAID 6 ~24TB)
  #
  # Same media share as pirateship. _netdev + x-systemd.automount means systemd
  # waits for network and mounts on first access — boot doesn't hang if erebor
  # is temporarily unavailable.
  # ---------------------------------------------------------------------------
  fileSystems."/var/lib/media" = {
    device = "erebor.theshire.io:/var/nfs/shared/media";
    fsType = "nfs";
    options = [ "_netdev" "nofail" "x-systemd.automount" "noauto" ];
  };

  # ---------------------------------------------------------------------------
  # System state version
  # ---------------------------------------------------------------------------

  system.stateVersion = "25.11";

  # ---------------------------------------------------------------------------
  # SOPS Secrets
  # ---------------------------------------------------------------------------

  sops = {
    defaultSopsFile = ../secrets/orthanc.yaml;
    defaultSopsFormat = "yaml";
    age.keyFile = "/var/lib/sops-nix/key.txt";

    secrets = {
      # JWT RS256 signing key for atticd — same secret format as was on mirkwood.
      # See modules/attic.nix for generation instructions.
      attic_env = {
        owner = "atticd";
      };

      # JWT push token for the post-build hook (orthanc is the builder, so it
      # also pushes its own outputs to the cache).
      attic_push_token = {};

      # Cloudflare Tunnel credentials for piped-backend WebSub (PubSubHubbub).
      # JSON file downloaded from Cloudflare Zero Trust → Networks → Tunnels.
      # Allows YouTube's hub to POST subscription notifications to piped-api.theshire.io
      # without requiring any inbound ports on the UDM Pro.
      cloudflared_piped_credentials = {
        owner = "cloudflared";
      };
      github_runner_token = {
        owner = "github-runner-orthanc";
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Cloudflare Tunnel — piped-backend WebSub ingress
  # ---------------------------------------------------------------------------
  #
  # Allows YouTube's PubSubHubbub hub to reach piped-backend at
  # piped-api.theshire.io without opening any inbound ports on the UDM Pro.
  # cloudflared opens an outbound connection to Cloudflare's edge; the hub
  # POSTs new video notifications inbound through that tunnel.
  #
  # DNS: after first deploy, create a CNAME in the Cloudflare dashboard:
  #   piped-api  →  <tunnel-id>.cfargotunnel.com  (Proxied)
  # This makes piped-api.theshire.io publicly reachable via Cloudflare.
  # Internal clients continue to hit Caddy on rivendell via split-horizon DNS.

  services.cloudflared = {
    enable = true;
    tunnels."piped-api" = {
      credentialsFile = config.sops.secrets.cloudflared_piped_credentials.path;
      ingress."piped-api.theshire.io" = "http://localhost:8180";
      ingress."stream.theshire.io"    = "http://pirateship.home.theshire.io:4533";
      default = "http_status:404";
    };
  };

  home-manager.users.brian = {
    imports = [ "${inputs.dotfiles}/machines/orthanc.nix" ];
  };

  # ---------------------------------------------------------------------------
  # GitHub Actions self-hosted runner — x86_64 pre-build for flake updates
  #
  # Builds orthanc's closure natively when Renovate opens a flake.lock PR.
  # Post-build hook pushes results to attic; subsequent deploys get cache hits.
  #
  # ---------------------------------------------------------------------------
  services.github-runners.orthanc = {
    enable = true;
    url = "https://github.com/bcrescimanno/homelab-nix";
    tokenFile = config.sops.secrets.github_runner_token.path;
    name = "orthanc";
    extraLabels = [ "nix-builder" ];
    replace = true;
    user = "github-runner-orthanc";
    extraPackages = with pkgs; [ nix git openssh ];
  };

  # ---------------------------------------------------------------------------
  # Backup
  # ---------------------------------------------------------------------------

  homelab.backup.paths = [
    "/var/lib/minecraft"
    "/var/lib/jellyfin"   # library database, config, plugins (not cache — auto-regenerates)
    "/var/lib/atticd"     # attic DB + NAR storage (GC retains last 2 weeks of entries)
  ];
}
