# modules/reboot-policy.nix — reboot after an upgrade that changed the kernel
#
# `nixos-rebuild switch` swaps in everything except the running kernel. Before
# this module nothing ever noticed: on 2026-09-18 orthanc had been running
# 6.18.40 for weeks with 6.18.51 installed, and nobody knew.
#
# homelab-reboot-check runs after homelab-upgrade-check SUCCEEDS, i.e. only
# after a clean nightly upgrade whose services all came back. A failed or
# rolled-back night never reaches it. It then does one of:
#
#   no reboot needed   nothing (and clears any stale state)
#   homelab.reboot.auto = false
#                      ntfy "reboot pending", every night until someone reboots
#   homelab.reboot.auto = true
#                      ntfy, then reboot — only inside the window, only if the
#                      DNS peer (if any) is answering, and never twice for the
#                      same kernel
#
# After the reboot, homelab-reboot-report re-runs the post-upgrade service
# check and reports whether the host came back healthy on the kernel it wanted.
#
# -----------------------------------------------------------------------------
# WHAT COUNTS AS "NEEDS A REBOOT"
#
# Only the kernel store path. Upstream system.autoUpgrade.allowReboot also
# compares initrd and kernel-modules, and that would be pure noise here: on
# 2026-09-18 all three Pis showed a different initrd AND kernel-modules from
# the booted system while running the identical kernel (the Pi kernel is
# pinned via nixos-raspberrypi and had not moved since 06-29). initrd only
# matters at the next boot, and modprobe resolves modules from
# /run/booted-system, so neither leaves the RUNNING system stale.
#
# -----------------------------------------------------------------------------
# WHY THE PIS ARE NOTIFY-ONLY
#
# A Pi that does not come back cannot be fixed remotely — there is no console,
# and deploy-rs' rollback covers activation, not boot. Their kernel moves a few
# times a year, so a "reboot pending" push costs almost nothing. Turn `auto` on
# per Pi once a few kernel bumps have been rebooted by hand without incident.
#
# Before enabling it on rivendell or mirkwood: they are the two DNS resolvers
# and must never be down together. `dnsPeer` makes each refuse to reboot unless
# the other is answering. pirateship additionally needs its VPN kill-switch
# latch and NFS mounts checked after boot — its post-upgrade service list does
# not cover those.
#
# -----------------------------------------------------------------------------
# REBOOT-LOOP GUARD
#
# If the new kernel fails and the machine comes back on an older one (manual
# pick at the boot menu, a fallback entry), booted != current would hold every
# night and an unguarded host would reboot nightly forever. The kernel we
# rebooted FOR is recorded; if we are still not on it, we alert and stop.
#
# Every branch exits 0 after notifying, same reasoning as the rollback script
# in post-upgrade-check.nix: this unit's failure must never be what fails an
# upgrade, and each branch sends its own precise message.

{ config, pkgs, lib, ... }:

let
  cfg      = config.homelab.reboot;
  ntfyUrl  = "http://10.0.1.9:2586/homelab";
  hostName = config.networking.hostName;
  stateDir = "/var/lib/homelab-reboot";
  # Kernel path we last rebooted to reach. Present only between the reboot
  # command and the post-boot report (or the loop guard tripping).
  attemptFile = "${stateDir}/attempted-kernel";

  svcList = config.homelab.postUpgradeCheck.services;

  coreutils = "${pkgs.coreutils}/bin";

  notify = ''
    notify() {
      # $1 priority, $2 tags, $3 title, $4 body
      ${pkgs.curl}/bin/curl -s \
        --connect-timeout 5 --max-time 30 --retry 5 --retry-delay 15 --retry-all-errors \
        -H "Title: $3" -H "Priority: $1" -H "Tags: $2" \
        -d "$4" ${ntfyUrl} || true
    }
  '';

  kernelVersion = path: ''$(${coreutils}/basename "$(${coreutils}/readlink -f ${path}/kernel-modules/lib/modules/*)")'';

  checkScript = pkgs.writeShellScript "homelab-reboot-check" ''
    set -uo pipefail
    ${notify}

    BOOTED=$(${coreutils}/readlink -f /run/booted-system/kernel)
    CURRENT=$(${coreutils}/readlink -f /run/current-system/kernel)
    RUNNING=${kernelVersion "/run/booted-system"}
    WANTED=${kernelVersion "/run/current-system"}

    if [[ "$BOOTED" == "$CURRENT" ]]; then
      ${coreutils}/rm -f ${attemptFile}
      echo "running kernel is current ($RUNNING); no reboot needed"
      exit 0
    fi

    echo "reboot needed: running $RUNNING, installed $WANTED"

    ${if !cfg.auto then ''
      notify 3 arrows_counterclockwise "Reboot pending" \
        "${hostName}: running kernel $RUNNING, installed $WANTED. Auto-reboot is off for this host — reboot by hand when convenient."
      exit 0
    '' else ''
      if [[ -f ${attemptFile} && "$(< ${attemptFile})" == "$CURRENT" ]]; then
        notify 5 rotating_light "Reboot did not take" \
          "${hostName}: already rebooted once to reach kernel $WANTED but is still running $RUNNING. Not retrying — check the boot loader and the console."
        exit 0
      fi

      HOUR=$(${coreutils}/date +%-H)
      if (( HOUR < ${toString cfg.window.start} || HOUR >= ${toString cfg.window.end} )); then
        notify 3 arrows_counterclockwise "Reboot pending" \
          "${hostName}: running kernel $RUNNING, installed $WANTED. Outside the ${toString cfg.window.start}:00–${toString cfg.window.end}:00 reboot window; will retry after the next nightly upgrade."
        exit 0
      fi

      ${lib.optionalString (cfg.dnsPeer != null) ''
        # Two tries a minute apart: the peer may itself be mid-upgrade.
        # Match an actual IPv4 answer, not "any output": on a timeout
        # `dig +short` prints ";; communications error ..." to STDOUT, so
        # `grep -q .` passed a dead peer (caught in testing, 2026-09-18).
        peer_ok=0
        for _ in 1 2; do
          if ${pkgs.dnsutils}/bin/dig +short +time=3 +tries=2 @${cfg.dnsPeer} theshire.io A \
               | ${pkgs.gnugrep}/bin/grep -qE '^[0-9]+(\.[0-9]+){3}$'; then
            peer_ok=1; break
          fi
          ${coreutils}/sleep 60
        done
        if (( ! peer_ok )); then
          notify 4 warning "Reboot deferred — DNS peer down" \
            "${hostName}: needs a reboot for kernel $WANTED, but the other resolver (${cfg.dnsPeer}) is not answering. Not taking both DNS hosts down; will retry tomorrow."
          exit 0
        fi
      ''}

      echo "$CURRENT" > ${attemptFile}
      notify 3 arrows_counterclockwise "Rebooting for new kernel" \
        "${hostName}: $RUNNING -> $WANTED. Expect a HostRebooted alert; a follow-up confirms the host came back."
      ${pkgs.systemd}/bin/systemctl reboot
    ''}
  '';

  reportScript = pkgs.writeShellScript "homelab-reboot-report" ''
    set -uo pipefail
    ${notify}

    # Not a reboot we asked for — manual, power cut, crash. Nothing to report;
    # HostRebooted in Grafana covers the unexplained ones.
    [[ -f ${attemptFile} ]] || exit 0

    WANTED_PATH=$(< ${attemptFile})
    BOOTED=$(${coreutils}/readlink -f /run/booted-system/kernel)
    RUNNING=$(${coreutils}/uname -r)

    if [[ "$BOOTED" != "$WANTED_PATH" ]]; then
      # Leave the attempt file: it is what stops tomorrow's check from
      # rebooting again. That check sends the loud alert; say it now too.
      notify 5 rotating_light "Rebooted onto the WRONG kernel" \
        "${hostName}: came back on $RUNNING, not the kernel it rebooted for. Will not retry automatically."
      exit 0
    fi

    ${coreutils}/rm -f ${attemptFile}

    # Services need a moment after boot before their state means anything;
    # containers in particular are still pulling/starting at multi-user.target.
    ${coreutils}/sleep 120

    failed=()
    for svc in ${lib.concatStringsSep " " svcList}; do
      status=$(${pkgs.systemd}/bin/systemctl is-active "$svc.service" 2>/dev/null || echo inactive)
      [[ "$status" == "active" ]] || failed+=("$svc: $status")
    done
    sysfailed=$(${pkgs.systemd}/bin/systemctl --failed --no-legend --plain | ${pkgs.gawk}/bin/awk '{print $1}' | ${coreutils}/tr '\n' ' ')

    if [[ ''${#failed[@]} -gt 0 || -n "$sysfailed" ]]; then
      notify 5 rotating_light "Rebooted — services DOWN" \
        "${hostName}: back on $RUNNING, but not healthy. Checked services: ''${failed[*]:-ok}. Failed units: ''${sysfailed:-none}."
      exit 0
    fi

    notify 2 white_check_mark "Reboot complete" \
      "${hostName}: back on $RUNNING, all checked services active, no failed units."
  '';
in

{
  options.homelab.reboot = {
    auto = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Reboot automatically after a clean nightly upgrade that installed a new
        kernel. When false the host only sends a nightly "reboot pending" push.
      '';
    };
    window = {
      start = lib.mkOption {
        type = lib.types.ints.between 0 23;
        default = 3;
        description = "Earliest local hour an automatic reboot may start.";
      };
      end = lib.mkOption {
        type = lib.types.ints.between 1 24;
        default = 7;
        description = "Hour (exclusive) after which an automatic reboot is deferred.";
      };
    };
    dnsPeer = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        IP of the other DNS resolver. When set, an automatic reboot is deferred
        unless that resolver is answering, so both are never down together.
      '';
    };
  };

  config = {
    systemd.tmpfiles.rules = [ "d ${stateDir} 0755 root root -" ];

    # Chain off the health check rather than the upgrade itself: a night that
    # failed its check has already been rolled back and must not reboot.
    systemd.services.homelab-upgrade-check.unitConfig.OnSuccess = "homelab-reboot-check.service";

    systemd.services.homelab-reboot-check = {
      description = "Reboot (or report a pending reboot) after a kernel upgrade";
      # Timer-chained oneshot: never let activation start it. See the note on
      # homelab-upgrade in base.nix — here a stray start could reboot the host
      # mid-deploy.
      restartIfChanged = false;
      unitConfig.X-OnlyManualStart = true;
      serviceConfig = {
        Type = "oneshot";
        # Covers the DNS-peer retry and the ntfy retries.
        TimeoutStartSec = "10m";
        ExecStart = toString checkScript;
      };
    };

    systemd.services.homelab-reboot-report = {
      description = "Report host health after a policy-driven reboot";
      wantedBy = [ "multi-user.target" ];
      after = [ "multi-user.target" "network-online.target" ];
      wants = [ "network-online.target" ];
      # Boot-only. A no-op without the attempt file, but there is no reason for
      # a deploy to run it at all.
      restartIfChanged = false;
      unitConfig.X-OnlyManualStart = true;
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "10m";
        ExecStart = toString reportScript;
      };
    };
  };
}
