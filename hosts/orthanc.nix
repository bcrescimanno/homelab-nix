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

      # Cloudflare Tunnel credentials — JSON downloaded from Cloudflare Zero
      # Trust → Networks → Tunnels. The "piped" in the name is HISTORICAL: the
      # tunnel was created for piped-backend's PubSubHubbub callbacks, Piped is
      # retired, and its only remaining ingress is Navidrome. Renaming this key
      # means renaming the tunnel in Cloudflare too — see the tunnel block below.
      cloudflared_piped_credentials = {
        owner = "cloudflared";
      };
      github_runner_token = {
        owner = "github-runner-orthanc";
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Cloudflare Tunnel — external ingress for Navidrome
  # ---------------------------------------------------------------------------
  #
  # cloudflared opens an OUTBOUND connection to Cloudflare's edge, so external
  # clients (Amperfy on cellular) reach stream.theshire.io without any inbound
  # port on the UDM Pro. Internal clients keep hitting Caddy on rivendell via
  # split-horizon DNS; only the public path goes through here.
  #
  # THE TUNNEL IS STILL NAMED "piped-api" AND THAT IS DELIBERATE. It was created
  # for piped-backend's PubSubHubbub callbacks; Piped is retired but the name is
  # load-bearing — nixpkgs writes the attribute name into cloudflared.yml as
  # `tunnel: piped-api` (the ExecStart passes no tunnel argument), and cloudflared
  # matches that against the tunnel's real name in Cloudflare. Renaming the
  # attribute alone breaks external Navidrome access. To rename properly:
  # rename the tunnel in the Cloudflare dashboard FIRST, then this attribute,
  # then the sops key above.
  #
  # DNS in Cloudflare: `stream` → <tunnel-id>.cfargotunnel.com (Proxied).
  # The `piped-api` CNAME that pointed at this same tunnel is dead — delete it.

  services.cloudflared = {
    enable = true;
    tunnels."piped-api" = {
      credentialsFile = config.sops.secrets.cloudflared_piped_credentials.path;
      ingress."stream.theshire.io" = "http://pirateship.home.theshire.io:4533";
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
    # No `package` override needed: Node 20 reached EOL and was removed from
    # nixpkgs, so github-runner now defaults to nodeRuntimes = [ "node24" ].
  };

  # ---------------------------------------------------------------------------
  # Backup
  # ---------------------------------------------------------------------------

  homelab.backup.paths = [
    "/var/lib/minecraft"                  # Prominence II world + server files
    "/var/lib/minecraft-abyssal-ascent"   # Abyssal Ascent world + server files
    "/var/lib/jellyfin"   # library database, config, plugins (not cache — auto-regenerates)
    # attic DB + NAR storage (GC retains last 2 weeks of entries).
    # The /var/lib/private prefix is REQUIRED — atticd runs with
    # DynamicUser=true, so /var/lib/atticd is only a symlink into
    # /var/lib/private/atticd and restic archives a symlink as a symlink.
    # This was "/var/lib/atticd" from 2026-04-03 to 2026-08-10 and every
    # snapshot in that window holds a single 0-byte symlink and no attic data.
    "/var/lib/private/atticd"
  ];
}
