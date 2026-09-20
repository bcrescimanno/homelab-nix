# modules/nut-secondary.nix — NUT secondary (upsmon in netclient mode)
#
# Until this module, NUT ran on rivendell ONLY, as upsmon type=primary, with no
# secondaries anywhere. mirkwood, pirateship and orthanc had no idea the power
# was out: during the 2026-08-09 outage (~19:57) they ran flat out until the
# battery died and then took an unclean power cut. This gives each of them the
# UPS signal and a graceful shutdown.
#
# -----------------------------------------------------------------------------
# HOW THE SHUTDOWN ACTUALLY HAPPENS — it is NOT "each host decides"
#
# Only rivendell's upsmon watches the battery. When the UPS goes critical (on
# battery + low battery) it sets FSD — forced shutdown — on upsd. Every
# secondary sees FSD in the UPS status and runs its own SHUTDOWNCMD (`shutdown
# now`, the NixOS default). The primary then waits HOSTSYNC seconds (15 by
# default) for the secondaries to disconnect before shutting itself down last.
#
# So the ordering is a property of the primary/secondary protocol, not of
# anything declared here, and rivendell going last is automatic. Nothing in this
# file needs to know about the other hosts.
#
# -----------------------------------------------------------------------------
# WHY A REBOOT OF RIVENDELL DOES NOT TAKE THESE HOSTS DOWN WITH IT
#
# This is the property that makes the module safe, and it is worth stating
# because the opposite would be catastrophic: rivendell reboots for kernel
# upgrades, and if that shut down the other three every time, this module would
# be far worse than the problem it fixes.
#
# From upsmon.conf(5), on DEADTIME — verified against the installed man page,
# not assumed:
#
#   "A dead UPS THAT WAS LAST KNOWN TO BE ON BATTERY is assumed to have changed
#    to a low battery condition. This may force a shutdown..."
#
# A UPS last known to be ONLINE and then unreachable is marked stale, then dead,
# and upsmon simply complains — it does not shut anything down, because it has
# no evidence of a power problem. A rivendell reboot on mains power therefore
# costs three log lines and nothing else.
#
# The converse is the fail-safe we want: if comms drop while the UPS is ON
# BATTERY, each secondary assumes the worst and shuts down rather than running
# until it crashes.
#
# TESTED, not just read: on 2026-09-19 17:17:28 upsd was stopped on rivendell for
# 40 seconds — comfortably past the 15s DEADTIME — while the UPS was OL. All
# three secondaries logged "Communications with UPS ... lost", retried every 5s,
# stayed up, and re-established on their own at 17:18:08-17:18:13 with no
# intervention and no ntfy push. Re-run that way if this is ever in doubt; do
# NOT test with `upsmon -c fsd`, which would shut down all four hosts for real.
#
# -----------------------------------------------------------------------------
# WHY upsdHost IS AN IP AND NOT A NAME
#
# This is power-failure infrastructure and must not depend on DNS. The
# 2026-08-09 restart already raced DNS against NFS — rivendell's
# var-lib-media-music.mount and pirateship's navidrome both failed because
# erebor.theshire.io would not resolve yet. Same reasoning, and the same
# literal, as ntfyUrl in modules/reboot-policy.nix and modules/grafana.nix.
# If rivendell's LAN IP ever changes, this changes with it.
#
# -----------------------------------------------------------------------------
# NOTIFICATIONS ARE DELIBERATELY QUIET HERE
#
# rivendell already pushes ONBATT/LOWBATT/ONLINE to ntfy from its own NOTIFYCMD
# (modules/nut.nix). If every secondary did the same, one power blip would send
# four identical pushes and the useful one would be lost in the noise.
# Secondaries therefore push only SHUTDOWN — the single event that is genuinely
# new information, "this host is going down now" — and log the rest to syslog.
#
# COMMBAD is syslog-only for that reason plus one more: every rivendell kernel
# reboot makes all three secondaries lose upsd briefly. With EXEC on COMMBAD
# that is three spurious pushes per kernel bump, which is exactly how an alert
# channel gets ignored. Per the paragraph above, losing comms while ONLINE
# cannot trigger a shutdown, so there is nothing there worth paging about.
#
# -----------------------------------------------------------------------------
# EARLY LOAD SHEDDING (homelab.ups.shed*)
#
# Everything above only gets a host down CLEANLY at the end of the battery. This
# section is about ending the outage for one host EARLY so the rest last longer.
#
# MEASURED 2026-09-19, which is what makes this worth doing at all:
#
#   ups.load 18%  → battery.runtime 3680s (61 min)   all four hosts idle
#   ups.load 29%  → battery.runtime 2036s (34 min)   orthanc at full CPU
#
# orthanc's CPU alone is 11 of those 18 load points, and taking it from idle to
# busy costs 27 minutes of runtime. By contrast the Pi 5s draw 1.9-2.7 W each on
# their internal rails (`vcgencmd pmic_read_adc`), so shedding a Pi buys
# essentially nothing.
#
# THAT IS THE WHOLE FINDING: orthanc is the only load worth shedding. erebor and
# the network gear are the other big draws and neither is ours to switch off. So
# this is deliberately not a general tiering framework — it is one lever, applied
# to one host, because that is where the measurement pointed.
#
# WHY A ROOT POLLER AND NOT AN ONBATT HOOK
#
# NOTIFYCMD runs UNPRIVILEGED: upsmon forks, the root parent handles only
# SHUTDOWNCMD, and the monitoring child drops to the upsmon user (`nutmon`). So
# an ONBATT handler cannot `poweroff`. The alternatives were a scoped polkit rule
# or a path-unit the notify script touches; a root timer reading `upsc` is the
# one with no IPC and no privilege escalation to reason about. It is one `upsc`
# call every 30s — this is NOT the auto-cpufreq pattern that was removed from
# hosts/orthanc.nix, which burned a core fraction continuously re-deciding
# something that never changed. This poll makes a decision nothing else can make
# with the privileges available.
#
# FAIL-SAFE DIRECTION IS "NEVER SHED ON UNCERTAINTY"
#
# If `upsc` fails — rivendell down, network gone, upsd restarting — the script
# does nothing and leaves the timer state untouched. An unreachable UPS is not
# evidence of an outage, and the cost of a wrong shed (a host off until someone
# presses a button) is far worse than the cost of a missed one (upsmon's FSD
# still catches the real end-of-battery case). Same discipline as the HA modules
# where `unavailable` is neither open nor closed.
#
# !! BEFORE ENABLING THIS ON A HOST, MAKE SURE YOU CAN GET IT BACK !!
#
# A shed host does NOT come back on its own. orthanc's BIOS still needs *Restore
# on AC Power Loss* (open since 2026-08-09, when it failed to return), and its
# Wake-on-LAN/PME setting is unverified. Until one of those is true, a 3-minute
# blip costs orthanc until someone physically presses power — so the shed
# notification says exactly that, loudly, rather than pretending it is routine.
# The natural follow-up is a WoL packet from rivendell (Tier 0, stays up) when
# the UPS returns to OL; that needs orthanc's MAC and BIOS WoL confirmed first.
#
# -----------------------------------------------------------------------------
# Secret required in each secondary's secrets/<host>.yaml:
#   nut_secondary_password — must match the same key in secrets/rivendell.yaml,
#                            which defines the matching upsd user.

{ config, lib, pkgs, ... }:

let
  shed = config.homelab.ups;
  upsdHost = "10.0.1.9"; # rivendell — IP on purpose, see header
  ntfyUrl = "http://10.0.1.9:2586/homelab";
  hostName = config.networking.hostName;

  # Only SHUTDOWN reaches this; everything else is SYSLOG-only below.
  #
  # Timeouts are short and there is no --retry, unlike the notify helpers
  # elsewhere in this repo: SHUTDOWNCMD runs right behind this, so a long retry
  # loop would just delay the clean shutdown it is announcing. A missed push is
  # the better failure — and rivendell, which hosts ntfy, is still up at this
  # point by the HOSTSYNC ordering described in the header.
  notify = pkgs.writeShellScript "nut-secondary-notify" ''
    if [ "$NOTIFYTYPE" = "SHUTDOWN" ]; then
      ${pkgs.curl}/bin/curl -s \
        --connect-timeout 5 --max-time 15 \
        -H "Title: UPS: ${hostName} shutting down" \
        -H "Priority: 5" \
        -H "Tags: skull" \
        -d "${hostName}: UPS $UPSNAME went critical. Shutting down cleanly." \
        ${ntfyUrl} || true
    fi
  '';
  upsName = "tripplite";

  shedScript = pkgs.writeShellScript "homelab-ups-shed" ''
    set -u
    PATH=${lib.makeBinPath [ config.power.ups.package pkgs.coreutils pkgs.curl pkgs.systemd ]}

    STATE=/run/homelab-ups-shed/onbatt-since

    # A failed query is NOT evidence of an outage. Leave the state alone and
    # come back next tick; upsmon's FSD path still covers real end-of-battery.
    if ! status=$(upsc ${upsName}@${upsdHost} ups.status 2>/dev/null); then
      echo "upsc unreachable — no decision"
      exit 0
    fi

    case "$status" in
      *OB*) ;;
      *)
        # Back on mains (or never left). Clear any accumulated time.
        if [ -f "$STATE" ]; then
          echo "mains restored (status=$status) — clearing shed timer"
          rm -f "$STATE"
        fi
        exit 0
        ;;
    esac

    now=$(date +%s)
    [ -f "$STATE" ] || echo "$now" > "$STATE"
    since=$(cat "$STATE")
    elapsed=$(( now - since ))

    # battery.charge is advisory here: a missing value must not veto the shed,
    # so an unreadable charge is treated as "no floor breach", never as 0.
    charge=$(upsc ${upsName}@${upsdHost} battery.charge 2>/dev/null || echo "")

    reason=""
    ${lib.optionalString (shed.shedAfterMinutes != null) ''
      if [ "$elapsed" -ge ${toString (shed.shedAfterMinutes * 60)} ]; then
        reason="on battery for $(( elapsed / 60 ))m"
      fi
    ''}
    ${lib.optionalString (shed.shedBelowCharge != null) ''
      if [ -n "$charge" ] && [ "''${charge%%.*}" -le ${toString shed.shedBelowCharge} ]; then
        reason="battery at ''${charge}%"
      fi
    ''}

    if [ -z "$reason" ]; then
      echo "on battery ''${elapsed}s (charge=''${charge:-unknown}) — holding"
      exit 0
    fi

    echo "shedding: $reason"
    curl -s --connect-timeout 5 --max-time 15 \
      -H "Title: UPS: shedding ${hostName}" \
      -H "Priority: 5" \
      -H "Tags: electric_plug" \
      -d "${hostName} is powering off to extend UPS runtime for the DNS pair ($reason, charge ''${charge:-unknown}%). IT WILL NOT COME BACK BY ITSELF — press power, or send a WoL packet, once mains is back." \
      ${ntfyUrl} || true

    systemctl poweroff
  '';
in

{
  options.homelab.ups = {
    shedAfterMinutes = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = ''
        Power this host off after it has been continuously on battery for this
        many minutes, to leave runtime for hosts that matter more. null disables
        shedding. Any sighting of mains power resets the counter, so short blips
        are ridden through rather than shed.

        A shed host does not return on its own — see the warning in the module
        header before setting this.
      '';
    };
    shedBelowCharge = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = ''
        Power this host off as soon as battery charge is at or below this
        percentage while on battery, regardless of how long the outage has run.
        Covers an outage that starts with an already-depleted battery. null
        disables the floor.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (shed.shedAfterMinutes != null || shed.shedBelowCharge != null) {
      systemd.tmpfiles.rules = [ "d /run/homelab-ups-shed 0700 root root -" ];

      systemd.services.homelab-ups-shed = {
        description = "Shed this host to extend UPS runtime";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${shedScript}";
        };
      };

      systemd.timers.homelab-ups-shed = {
        description = "Poll UPS state for early load shedding";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "30s";
          AccuracySec = "5s";
          Unit = "homelab-ups-shed.service";
        };
      };
    })

    {
  power.ups = {
    enable = true;

    # netclient starts upsmon only — no driver, no upsd. The UPS is on
    # rivendell's USB and this host never talks to the hardware.
    mode = "netclient";

    upsmon = {
      monitor.tripplite = {
        system = "tripplite@${upsdHost}";

        # This host IS fed by the UPS, so it declares one power supply. With the
        # default MINSUPPLIES=1 that is what makes an FSD actionable here; 0
        # would mean "just watching someone else's UPS" and would never shut
        # this host down.
        powerValue = 1;

        user = "upsmon-secondary";
        passwordFile = config.sops.secrets.nut_secondary_password.path;
        type = "secondary";
      };

      settings = {
        NOTIFYCMD = "${notify}";
        NOTIFYFLAG = [
          [ "ONBATT" "SYSLOG" ]
          [ "LOWBATT" "SYSLOG" ]
          [ "ONLINE" "SYSLOG" ]
          [ "COMMBAD" "SYSLOG" ]
          [ "COMMOK" "SYSLOG" ]
          [ "SHUTDOWN" "SYSLOG+EXEC" ]
        ];
      };
    };
  };

      homelab.postUpgradeCheck.services = [ "upsmon" ];
    }
  ];
}
