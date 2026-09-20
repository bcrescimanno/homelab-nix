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
  # It is what makes the powersave governor + EPP setting below meaningful on
  # Zen 3 — without it the driver falls back to acpi-cpufreq, which has no EPP.
  boot.kernelParams = [ "amd_pstate=active" ];

  # AMD microcode updates — apply latest CPU microcode on boot.
  hardware.cpu.amd.updateMicrocode = true;

  # ---------------------------------------------------------------------------
  # Power management
  # ---------------------------------------------------------------------------
  #
  # The target state is the same one auto-cpufreq used to apply — "powersave"
  # governor with "balance_power" EPP — but applied ONCE at boot instead of by
  # a polling daemon.
  #
  # auto-cpufreq was removed 2026-09-19. With amd_pstate=active the scaling
  # decision happens in the CPU's own hardware: the governor and EPP are hints
  # the firmware acts on per-microsecond, and userspace re-deciding them on a
  # poll interval adds nothing. Measured on orthanc that day, it was the single
  # largest CPU consumer on the host by cumulative time — ~6.8% of a core
  # averaged since boot, more than either Minecraft server — to re-apply values
  # that never changed. Stopping it moved package power 31W → 29W (inside the
  # noise, but in the right direction); the real argument is that it burns a
  # core fraction continuously for no decision.
  #
  # Do not reintroduce it, or power-profiles-daemon, without a measurement
  # showing the hardware governor is actually mis-scaling for this workload.
  powerManagement.cpuFreqGovernor = "powersave";

  # EPP has no NixOS option, so set it directly. amd-pstate-epp defaults to
  # "balance_performance" under the powersave governor, which holds higher
  # clocks at idle than this box needs — it spends almost all its time waiting
  # for a build or a game tick.
  systemd.services.cpu-epp = {
    description = "Set AMD P-State energy performance preference";
    wantedBy = [ "multi-user.target" ];
    after = [ "cpufreq.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      shopt -s nullglob
      for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        echo balance_power > "$f"
      done
    '';
  };

  # powertop --auto-tune at boot: runtime PM for PCIe devices, the USB bus and
  # the SATA links. Safe here because orthanc is headless with nothing on USB
  # but a hub and the motherboard's RGB controller, and nothing on SATA (root
  # is NVMe) — the devices autosuspend touches are ones nothing uses.
  #
  # This does NOT enable PCIe ASPM, which is disabled on every link on this
  # board and is a BIOS setting, not a kernel one.
  powerManagement.powertop.enable = true;

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

      # Shared credential the NUT secondary uses to authenticate to rivendell's
      # upsd (modules/nut-secondary.nix). Must hold the same value as
      # nut_secondary_password in secrets/rivendell.yaml, which defines the
      # matching upsd user. Default 0400 root:root is correct — systemd reads it
      # via LoadCredential as root before upsmon drops privileges.
      nut_secondary_password = {};

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
  # UPS load shedding
  # ---------------------------------------------------------------------------
  #
  # orthanc is the ONLY load on the UPS worth shedding, and this is measured
  # rather than assumed (2026-09-19): its CPU alone is 11 of the 18 ups.load
  # points, and driving it from idle to full took battery.runtime from 3680s
  # (61 min) to 2036s (34 min). The three Pi 5s draw 1.9-2.7 W each on their
  # internal rails, so shedding one of those buys nothing; erebor and the network
  # gear are the other large draws and neither is ours to switch off.
  #
  # Nothing orthanc runs is needed during a power cut — Minecraft, Invidious,
  # the attic cache, the CI runner and Jellyfin are all discretionary. Five
  # minutes rides through the blips that make up most outages while still
  # shedding long before the battery is meaningfully down; the 50% floor covers
  # an outage that begins with an already-depleted battery.
  #
  # !! orthanc DOES NOT COME BACK BY ITSELF !! Its BIOS still needs *Restore on
  # AC Power Loss* (open since it failed to return on 2026-08-09) and its
  # Wake-on-LAN/PME state is unverified. Until one of those is sorted, a shed
  # costs orthanc until someone presses power — which is why the shed push says
  # so explicitly. See the header of modules/nut-secondary.nix.
  homelab.ups = {
    shedAfterMinutes = 5;
    shedBelowCharge = 50;
  };

  # Wake-on-LAN, so a shed orthanc can be brought back without a physical press.
  #
  # THIS IS THE MECHANISM THAT MATTERS, and *Restore on AC Power Loss* is not a
  # substitute for it. A shed is `systemctl poweroff` while the UPS is still
  # happily supplying AC, so the PSU keeps standby power and the BIOS never sees
  # an AC transition to restore from. The two settings cover disjoint cases:
  #
  #   shed, then mains returns   → no AC transition → only WoL can help  ← common
  #   battery ran flat, UPS cut  → PSU lost standby → only the BIOS can help
  #
  # So both are wanted. This half is the one that covers the likely outage.
  #
  # Verified on the hardware 2026-09-19: `ethtool enp5s0` reported
  # `Supports Wake-on: pumbg` (magic packet available) but `Wake-on: d`
  # (disabled), so nothing would have woken. nixpkgs implements this as a
  # systemd .link file, which udev applies even though this host uses the
  # scripted/dhcpcd backend rather than networkd — confirmed by the comment in
  # nixos/modules/tasks/network-interfaces.nix. The NIC keeps the setting across
  # a soft poweroff because standby power remains; it is re-applied on each boot.
  #
  # enp5s0 is the 10.0.1.10 LAN port. enp6s0 and wlp4s0 are deliberately left
  # alone — the waker on rivendell broadcasts to the LAN.
  networking.interfaces.enp5s0.wakeOnLan.enable = true;

  # ---------------------------------------------------------------------------
  # Cloudflare Tunnel — external ingress for Navidrome and Vaultwarden
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
  # DNS in Cloudflare: `stream` and `vault` → <tunnel-id>.cfargotunnel.com
  # (Proxied). Neither record is declared here — both were created by hand.
  # The `piped-api` CNAME that pointed at this same tunnel is dead — delete it.

  services.cloudflared = {
    enable = true;
    tunnels."piped-api" = {
      credentialsFile = config.sops.secrets.cloudflared_piped_credentials.path;
      ingress."stream.theshire.io" = "http://pirateship.home.theshire.io:4533";

      # Vaultwarden. Goes THROUGH Caddy on rivendell, not straight to the
      # backend like stream does: Vaultwarden listens on 127.0.0.1 only, and
      # the vault vhost is where the real client IP (CF-Connecting-IP) is
      # turned into X-Real-IP for the login rate limit — keyed on this
      # tunnel's source address, 10.0.1.10. See the vault vhost in
      # modules/caddy.nix before changing either end.
      #
      # By IP, not rivendell.home.theshire.io: that name can resolve to an
      # IPv6 address, which would miss Caddy's `remote_ip 10.0.1.10` matcher and
      # silently send every public request down the LAN path (client IP =
      # orthanc). originServerName makes cloudflared send the right SNI and
      # verify Caddy's real vault.theshire.io certificate — no noTLSVerify.
      ingress."vault.theshire.io" = {
        service = "https://10.0.1.9";
        originRequest.originServerName = "vault.theshire.io";
      };
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

  # Reboot automatically when a nightly upgrade installs a new kernel (inside
  # 03:00–07:00, after the post-upgrade check passes). See
  # modules/reboot-policy.nix.
  homelab.reboot.auto = true;

  homelab.backup.paths = [
    "/var/lib/minecraft"                  # Prominence II world + server files
    "/var/lib/minecraft-abyssal-ascent"   # Abyssal Ascent world + server files
    "/var/lib/jellyfin"   # library database, config, plugins (not cache — auto-regenerates)
    # attic DB + NAR storage (GC retention is `default-retention-period` in
    # modules/attic.nix — deliberately not repeated here).
    # The /var/lib/private prefix is REQUIRED — atticd runs with
    # DynamicUser=true, so /var/lib/atticd is only a symlink into
    # /var/lib/private/atticd and restic archives a symlink as a symlink.
    # This was "/var/lib/atticd" from 2026-04-03 to 2026-08-10 and every
    # snapshot in that window holds a single 0-byte symlink and no attic data.
    "/var/lib/private/atticd"
  ];
}
