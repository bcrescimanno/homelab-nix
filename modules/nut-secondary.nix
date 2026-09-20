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
# NOT DONE HERE — staged / early shutdown
#
# Powering pirateship and orthanc off EARLY, to leave battery runtime for the
# DNS pair, is the load-shedding tier work in Plan.md → Power / Battery
# Resilience. It is deliberately not attempted here. Two things block it, both
# found while writing this module:
#
#   1. It needs an answer to "is orthanc even on the UPS?", still open in
#      Plan.md. orthanc did not come back after 2026-08-09 and its BIOS needs
#      *Restore on AC Power Loss* regardless of anything NUT does.
#
#   2. NOTIFYCMD runs UNPRIVILEGED. upsmon forks: the root parent handles only
#      SHUTDOWNCMD, and the monitoring child drops to the upsmon user
#      (`nutmon` by default in nixpkgs, and unchanged here). So an ONBATT
#      handler cannot `systemctl` or `poweroff` by itself. Staged shutdown needs
#      a deliberate privilege path — a narrowly scoped polkit rule, a path-unit
#      the notify script touches, or a root poller on `upsc`. Choose one when
#      the tiers are designed; do not sprinkle sudo into a notify script.
#
# -----------------------------------------------------------------------------
# Secret required in each secondary's secrets/<host>.yaml:
#   nut_secondary_password — must match the same key in secrets/rivendell.yaml,
#                            which defines the matching upsd user.

{ config, pkgs, ... }:

let
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
in

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
