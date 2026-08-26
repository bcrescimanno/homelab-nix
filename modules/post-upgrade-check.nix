# modules/post-upgrade-check.nix — post-upgrade health check and automatic rollback
#
# Runs after homelab-upgrade.service succeeds. Verifies that every service
# module declared in homelab.postUpgradeCheck.services is active, and if any
# is not, reverts the host to the exact system it was running before.
#
# Service modules opt in by adding:
#   homelab.postUpgradeCheck.services = [ "my-service" ];
# Lists from all imported modules are merged automatically.
#
# -----------------------------------------------------------------------------
# WHY THE ROLLBACK EXISTS
#
# The unattended path is nixos-rebuild switch, NOT deploy-rs, so it has none of
# deploy-rs' magic/auto rollback. Until now a bad closure landed at 04:20, broke
# a service, sent one priority-4 ntfy and then simply stayed broken until
# somebody read their phone. That was a defensible risk while every flake.lock
# change was hand-shepherded through scripts/merge-renovate. It stops being
# defensible the moment lock updates automerge, which is the point of this work.
#
# -----------------------------------------------------------------------------
# WHY A RECORDED STORE PATH AND NOT `nixos-rebuild switch --rollback`
#
# --rollback moves to the previous GENERATION, which is only the pre-upgrade
# system if the upgrade actually created a new one. nixos-rebuild does not
# create a generation when the closure is unchanged, so on a no-op upgrade night
# --rollback would silently revert a generation FURTHER back than intended —
# undoing whatever legitimately landed the day before, for a fault it did not
# cause. Recording the resolved store path in ExecStartPre and switching back to
# exactly that path is immune to this: it either reverts the change that just
# happened or it does nothing.
#
# The same recording gives the three guards below, all of which refuse rather
# than guess:
#
#   prev == current   The closure never changed, so the failing service was
#                     already failing before this run. Not a regression; there
#                     is nothing to roll back TO. Reverting here would be a
#                     no-op at best and a false lead at worst.
#   prev missing      No ExecStartPre ran (first boot after this lands).
#   prev collected    The path lost to a GC between then and now.
#
# -----------------------------------------------------------------------------
# INTERACTION WITH THE FRESHNESS DEAD-MAN'S SWITCH
#
# modules/backup.nix stamps /var/lib/homelab-freshness/homelab-upgrade-check
# from ExecStopPost, guarded on SERVICE_RESULT=success. A rolled-back night
# leaves the check failed and therefore leaves NO stamp, so if the same bad
# revision keeps landing the 36h switch escalates on its own. That is correct
# and deliberate: a host that reverts every night is not upgrading, and should
# not look like it is. Do not "fix" this by stamping on the rollback path.

{ config, pkgs, lib, ... }:

let
  ntfyUrl  = "http://10.0.1.9:2586/homelab";
  hostName = config.networking.hostName;
  stateDir = "/var/lib/homelab-upgrade";
  prevFile = "${stateDir}/previous-system";

  svcList = config.homelab.postUpgradeCheck.services;

  # One definition of "are the declared services up", used by the check AND by
  # the rollback's re-verification. Two copies would drift, and the re-verify is
  # only meaningful if it asks exactly the question that failed.
  checkServices = ''
    failed=()
    for svc in ${lib.concatStringsSep " " svcList}; do
      status=$(systemctl is-active "$svc.service" 2>/dev/null || echo inactive)
      [[ "$status" == "active" ]] || failed+=("$svc: $status")
    done
  '';

  notify = ''
    notify() {
      # $1 priority, $2 tags, $3 title, $4 body
      ${pkgs.curl}/bin/curl -s \
        --connect-timeout 5 --max-time 30 --retry 5 --retry-delay 15 --retry-all-errors \
        -H "Title: $3" -H "Priority: $1" -H "Tags: $2" \
        -d "$4" ${ntfyUrl} || true
    }
  '';
in

{
  options.homelab.postUpgradeCheck.services = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    description = "systemd service names to verify are active after upgrade";
  };

  config = {
    # Record what we are running BEFORE the upgrade replaces it. Lives here
    # rather than beside the unit in base.nix because it exists solely to feed
    # the rollback below.
    systemd.services.homelab-upgrade.serviceConfig = {
      StateDirectory = "homelab-upgrade";
      ExecStartPre = toString (pkgs.writeShellScript "homelab-upgrade-record-previous" ''
        ${pkgs.coreutils}/bin/readlink -f /run/current-system > ${prevFile}
      '');
    };

    systemd.services.homelab-upgrade-check = {
      description = "Post-upgrade service health check";
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = 10;
        ExecStart =
          let
            script =
              if svcList == [] then "exit 0"
              else ''
                ${checkServices}
                if [[ ''${#failed[@]} -gt 0 ]]; then
                  echo "post-upgrade checks failed: ''${failed[*]}" >&2
                  exit 1
                fi
              '';
          in toString (pkgs.writeShellScript "homelab-upgrade-check" script);
      };
      unitConfig = {
        OnFailure = "homelab-upgrade-rollback.service";
      };
    };

    systemd.services.homelab-upgrade-rollback = {
      description = "Roll back a NixOS upgrade that left services unhealthy";
      serviceConfig = {
        Type = "oneshot";
        # switch-to-configuration plus a settle window plus re-verification.
        TimeoutStartSec = "10m";
        ExecStart = toString (pkgs.writeShellScript "homelab-upgrade-rollback" ''
          set -uo pipefail
          ${notify}

          # EVERY branch below exits 0, including the ones that refuse and the
          # one that rolls back and finds the host still broken. That looks
          # wrong and is deliberate: exiting non-zero fires this unit's
          # OnFailure, which is the last-resort notifier, and the branch has
          # already sent a precise alert of its own. Verified on orthanc
          # 2026-08-26 by firing the prev==current guard for real — it produced
          # two contradictory priority-5 messages, the guard's own correct one
          # plus "the rollback did not complete", which was false.
          #
          # The unit result answers "did the rollback service do its job",
          # not "is the host healthy" — the notification and the freshness
          # dead-man's switch on homelab-upgrade-check answer that. A non-zero
          # exit here is therefore reserved for the one case the script cannot
          # report on: dying before it can notify.

          CURRENT=$(${pkgs.coreutils}/bin/readlink -f /run/current-system)

          if [[ ! -f ${prevFile} ]]; then
            notify 5 rotating_light "Upgrade unhealthy — NO ROLLBACK" \
              "${hostName}: services failed the post-upgrade check but no pre-upgrade system was recorded, so there is nothing to revert to. Check journalctl -u homelab-upgrade-check."
            exit 0
          fi

          PREVIOUS=$(< ${prevFile})

          if [[ "$PREVIOUS" == "$CURRENT" ]]; then
            notify 5 rotating_light "Services unhealthy — NOT an upgrade regression" \
              "${hostName}: the post-upgrade check failed but the system closure did not change, so this was already broken before tonight's run. Not rolling back. See journalctl -u homelab-upgrade-check."
            exit 0
          fi

          if [[ ! -e "$PREVIOUS" ]]; then
            notify 5 rotating_light "Upgrade unhealthy — ROLLBACK IMPOSSIBLE" \
              "${hostName}: wanted to revert to $PREVIOUS but it has been garbage collected. Host is running the bad configuration. Manual intervention required."
            exit 0
          fi

          echo "rolling back: $CURRENT -> $PREVIOUS" >&2
          ${config.nix.package}/bin/nix-env --profile /nix/var/nix/profiles/system --set "$PREVIOUS"
          "$PREVIOUS/bin/switch-to-configuration" switch

          # Units restarted by the switch need a moment before their state means
          # anything. The check that got us here runs with TimeoutStartSec=10
          # immediately after activation; re-asking that fast would just
          # reproduce a race rather than answer the question.
          ${pkgs.coreutils}/bin/sleep 20

          ${checkServices}

          if [[ ''${#failed[@]} -gt 0 ]]; then
            notify 5 rotating_light "Rolled back — STILL UNHEALTHY" \
              "${hostName}: reverted to $(${pkgs.coreutils}/bin/basename "$PREVIOUS") but these are still down: ''${failed[*]}. The upgrade was not the cause. Manual intervention required."
            exit 0
          fi

          notify 4 warning "Upgrade rolled back — services recovered" \
            "${hostName}: post-upgrade check failed, reverted $(${pkgs.coreutils}/bin/basename "$CURRENT") -> $(${pkgs.coreutils}/bin/basename "$PREVIOUS") and all services are healthy again. main is carrying a bad change for this host."
        '');
      };
      # Last resort, and now genuinely last: every branch of the script above
      # exits 0 after notifying, so this fires only if the script died before
      # it could report — killed, or broken badly enough not to reach a notify.
      unitConfig.OnFailure = "homelab-upgrade-notify-unhealthy.service";
    };

    systemd.services.homelab-upgrade-notify-unhealthy = {
      description = "Notify ntfy of post-upgrade health check failure";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.curl}/bin/curl -s "
          + "--connect-timeout 5 --max-time 30 --retry 5 --retry-delay 15 --retry-all-errors "
          + "-H 'Title: NixOS Upgraded but Unhealthy' "
          + "-H 'Priority: 5' "
          + "-H 'Tags: rotating_light' "
          + "-d '${hostName} failed the post-upgrade check and the rollback service died without reporting — see journalctl -u homelab-upgrade-rollback' "
          + "${ntfyUrl}";
      };
    };
  };
}
