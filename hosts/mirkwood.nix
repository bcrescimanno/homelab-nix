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
      # SSH private key used by the upgrade orchestrator to trigger
      # homelab-upgrade.service on rivendell and pirateship via SSH.
      # Generate with: ssh-keygen -t ed25519 -f homelab-deploy -C "mirkwood-deploy" -N ""
      # Then: sops secrets/mirkwood.yaml  (add deploy_key: <base64 or raw key>)
      # And add the public key to users.users.brian.openssh.authorizedKeys.keys in base.nix.
      deploy_key = {
        owner = "root";
        mode = "0600";
      };
    };
  };

  home-manager.users.brian = {
    imports = [ "${inputs.dotfiles}/machines/mirkwood.nix" ];
  };

  # ---------------------------------------------------------------------------
  # Upgrade orchestrator
  # ---------------------------------------------------------------------------
  #
  # mirkwood is the designated upgrade orchestrator for the homelab fleet.
  # On each run it:
  #   1. Triggers homelab-upgrade.service locally (builds mirkwood's closure,
  #      which includes the shared kernel; post-build hooks push to attic cache)
  #   2. After mirkwood's upgrade completes, triggers homelab-upgrade.service
  #      on rivendell and pirateship in parallel via SSH — they fetch shared
  #      packages from the attic cache rather than rebuilding them.
  #
  # Each host sends its own ntfy notification via homelab-upgrade-notify-*.
  # This service sends an additional notification only on orchestration failure
  # (e.g. SSH connection refused, or mirkwood's own upgrade failed before the
  # remote triggers fired).

  systemd.services.homelab-upgrade-orchestrator = {
    description = "Homelab upgrade orchestrator";
    requires = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = toString (pkgs.writeShellScript "homelab-upgrade-orchestrate" ''
        set -euo pipefail

        # Step 1: Upgrade mirkwood. Blocks until complete; exits non-zero on
        # failure so we do not trigger remote hosts against a broken cache state.
        # homelab-upgrade.service sends its own ntfy notification on success/failure.
        systemctl start homelab-upgrade

        # Step 2: Trigger rivendell and pirateship in parallel.
        # Each host fetches shared derivations (kernel, etc.) from attic and
        # handles its own ntfy notification.
        _upgrade_remote() {
          ssh \
            -i /run/secrets/deploy_key \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=30 \
            brian@"$1".home.theshire.io \
            "sudo systemctl start homelab-upgrade"
        }

        _upgrade_remote rivendell &
        pid_r=$!
        _upgrade_remote pirateship &
        pid_p=$!

        status=0
        wait "$pid_r" || status=$?
        wait "$pid_p" || { [[ $status -eq 0 ]] && status=$?; }
        exit $status
      '');
    };
    unitConfig = {
      OnFailure = "homelab-upgrade-orchestrator-notify-failure.service";
    };
  };

  systemd.timers.homelab-upgrade-orchestrator = {
    description = "Daily homelab upgrade orchestration";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "04:00";
      Persistent = true;
    };
  };

  # Fires only when the orchestrator itself fails (mirkwood upgrade failed, or
  # SSH to a remote host failed). Per-host upgrade failures are reported by
  # homelab-upgrade-notify-failure.service on the affected host.
  systemd.services.homelab-upgrade-orchestrator-notify-failure = {
    description = "Notify ntfy of failed upgrade orchestration";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.curl}/bin/curl -s "
        + "--connect-timeout 5 --max-time 30 --retry 5 --retry-delay 15 --retry-all-errors "
        + "-H 'Title: Homelab Upgrade Orchestration FAILED' "
        + "-H 'Priority: 4' "
        + "-H 'Tags: rotating_light' "
        + "-d 'Upgrade orchestration failed on mirkwood — one or more hosts may not have upgraded. Check: journalctl -u homelab-upgrade-orchestrator' "
        + "http://10.0.1.9:2586/homelab";
    };
  };

  # ---------------------------------------------------------------------------
  # Backup
  # ---------------------------------------------------------------------------
  homelab.backup.paths = [
    "/var/lib/grafana"
  ];
}
