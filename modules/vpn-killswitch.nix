# modules/vpn-killswitch.nix — leak detector + hard latch for the arr stack VPN
#
# gluetun already IS a kill switch: iptables OUTPUT policy DROP with eth0
# permitted only for the podman bridge, the WireGuard endpoint, and the single
# /32 LAN exception. If tun0 dies, packets route to a dead interface and are
# dropped. Verified 2026-08-02 — see modules/arr-stack.nix and the
# gluetun-lan-exception notes.
#
# What was missing is not enforcement, it is DETECTION. Every existing check
# around this stack is blind to the tunnel:
#
#   * Gatus "gluetun VPN" is a bare TCP connect to pirateship:8000. The control
#     server listens on `:::8000` inside the netns and does not depend on tun0
#     at all, so that check stays green with the tunnel completely down.
#   * The Gatus HTTP checks (qBittorrent/Radarr/...) hit web UIs that bind
#     inside the netns and are reached over the podman bridge — also tun0
#     independent, also green.
#   * `UnitFailed` cannot see it: gluetun retries internally and never exits.
#   * `gluetun-watchdog` is the only thing that notices, and only indirectly
#     (NAT-PMP port forwarding needs the tunnel). Its response is to RESTART,
#     which is the right response to a dead tunnel and the wrong one to a
#     leaking tunnel.
#
# So nothing here could distinguish "tunnel healthy" from "tunnel down" from
# "traffic escaping", and nothing at all watched the firewall rules.
#
# DESIGN — trip only on a POSITIVE leak signal, never on absence of evidence.
# A container that cannot reach the internet is the kill switch WORKING; that
# must never trip the latch. Only two things count as a leak:
#
#   1. The netns reports a public IP equal to the host's public IP. That means
#      packets left via eth0 carrying the home address, which is the actual
#      harm being defended against.
#   2. The gluetun firewall is not in its expected shape — OUTPUT policy is not
#      DROP, or an eth0 ACCEPT rule names a destination outside the allowlist.
#      This is the config-drift case (someone widens FIREWALL_OUTBOUND_SUBNETS,
#      a future image changes defaults) which produces no symptom until it
#      matters.
#
# Anything else — exec failure, timeout, empty answer — is UNKNOWN and is
# reported as such, never acted on. Two consecutive bad verdicts are required
# before tripping so a single bad read cannot take the stack down.
#
# ON TRIP the whole stack is stopped and LATCHED OFF. The latch is a file, and
# podman-gluetun gets an ExecStartPre that refuses to start while it exists —
# so a reboot, a deploy, or the 05:00 auto-upgrade cannot quietly bring the
# stack back up with an unexplained leak still in place. That is deliberate:
# "disabled until troubleshooting happens" means a human has to clear it.
#
#   Clear with:  sudo rm /var/lib/vpn-killswitch/tripped
#                sudo systemctl start podman-gluetun podman-qbittorrent \
#                  podman-sabnzbd podman-radarr podman-sonarr \
#                  podman-prowlarr podman-lidarr
#
# Starting podman-gluetun alone is NOT enough and this was verified the hard
# way: Requires= propagates downward (stopping gluetun stops the consumers,
# and restarting it restarts them) but it does not pull stopped consumers back
# up when gluetun starts on its own. Measured 2026-08-02 — after a test trip,
# `systemctl start podman-gluetun` brought back gluetun and nothing else.
#
# Metrics go to node_exporter's textfile collector (modules/monitoring.nix) and
# are alerted on in the `vpn` rule group in modules/grafana.nix. The staleness
# metric matters as much as the leak metric: without it, a detector that
# silently died looks exactly like a network with no leaks.

{ config, pkgs, lib, ... }:

let
  stateDir   = "/var/lib/vpn-killswitch";
  latchFile  = "${stateDir}/tripped";
  metricFile = "/var/lib/prometheus-textfiles/vpn_killswitch.prom";
  ntfyUrl    = "http://10.0.1.9:2586/homelab";

  # Every container sharing gluetun's netns, plus gluetun itself. Order matters
  # on stop: drop the consumers before the tunnel they ride on.
  stackUnits = [
    "podman-qbittorrent" "podman-sabnzbd"  "podman-radarr"
    "podman-sonarr"      "podman-prowlarr" "podman-lidarr"
    "podman-gluetun"
  ];

  # The only destination-scoped OUTPUT ACCEPTs gluetun is expected to have on
  # eth0. Kept in sync by hand with FIREWALL_OUTBOUND_SUBNETS in arr-stack.nix
  # — if you widen that, widen this too, and understand that doing so is the
  # exact thing this check exists to catch.
  allowedOutboundDests = [ "10.88.0.0/16" "10.0.1.10/32" ];
in
{
  systemd.services.vpn-leak-check = {
    description = "Verify the arr stack VPN is not leaking; latch the stack off if it is";
    after = [ "podman-gluetun.service" "network-online.target" ];
    wants = [ "network-online.target" ];

    path = with pkgs; [ podman curl coreutils gnugrep gawk systemd ];

    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "vpn-killswitch";
    };

    # Deliberately NOT `set -e`: a probe that fails must fall through to the
    # UNKNOWN path and still publish metrics, not abort the unit. Unit failure
    # here would make UnitFailed fire on every transient network blip.
    script = ''
      set -uo pipefail

      LATCH="${latchFile}"
      STRIKE_FILE="${stateDir}/strikes"

      write_metrics() {
        # $1 tripped  $2 tunnel_up  $3 egress_matches_host  $4 firewall_intact
        [ -d /var/lib/prometheus-textfiles ] || return 0
        tmp=$(mktemp -p /var/lib/prometheus-textfiles) || return 0
        {
          printf '# HELP vpn_killswitch_tripped Arr stack latched off after a confirmed VPN leak\n'
          printf '# TYPE vpn_killswitch_tripped gauge\n'
          printf 'vpn_killswitch_tripped %s\n' "$1"
          printf '# HELP vpn_tunnel_up The gluetun netns can reach the internet\n'
          printf '# TYPE vpn_tunnel_up gauge\n'
          printf 'vpn_tunnel_up %s\n' "$2"
          printf '# HELP vpn_egress_matches_host Netns public IP equals the host public IP (a leak)\n'
          printf '# TYPE vpn_egress_matches_host gauge\n'
          printf 'vpn_egress_matches_host %s\n' "$3"
          printf '# HELP vpn_firewall_intact gluetun OUTPUT policy is DROP and the egress allowlist is unwidened\n'
          printf '# TYPE vpn_firewall_intact gauge\n'
          printf 'vpn_firewall_intact %s\n' "$4"
          printf '# HELP vpn_leak_check_timestamp_seconds Unix time of the last completed leak check\n'
          printf '# TYPE vpn_leak_check_timestamp_seconds gauge\n'
          printf 'vpn_leak_check_timestamp_seconds %s\n' "$(date +%s)"
        } > "$tmp"
        chmod 0644 "$tmp"
        mv "$tmp" "${metricFile}"
      }

      # Already latched: publish the state and stop. Do not re-probe, do not
      # re-notify — the stack is down and a human owes it a look.
      if [ -e "$LATCH" ]; then
        write_metrics 1 0 0 0
        exit 0
      fi

      # ---- probe 1: does the netns egress from an address that is not ours? --
      # Both probes hit the same service so the two answers are comparable. The
      # host probe takes the normal path; the netns probe must traverse tun0 or
      # it cannot answer at all.
      HOST_IP=$(curl -s --max-time 15 https://api.ipify.org 2>/dev/null || true)
      NS_IP=$(timeout 25 podman exec gluetun \
                wget -qO- -T 15 https://api.ipify.org 2>/dev/null || true)

      # ---- probe 2: is the firewall still shaped the way we think? ----------
      FW_RULES=$(timeout 15 podman exec gluetun iptables -S OUTPUT 2>/dev/null || true)

      TUNNEL_UP=0
      LEAK=0
      FW_INTACT=1
      REASON=""

      if [ -n "$NS_IP" ]; then
        TUNNEL_UP=1
        if [ -n "$HOST_IP" ] && [ "$NS_IP" = "$HOST_IP" ]; then
          LEAK=1
          REASON="netns egress IP $NS_IP equals the host public IP — traffic is leaving via eth0, NOT the tunnel"
        fi
      fi

      # An unreadable ruleset is UNKNOWN, not a violation: podman exec can fail
      # while the firewall is perfectly fine. Only a ruleset we can read and
      # that disagrees with expectations counts against it.
      if [ -n "$FW_RULES" ]; then
        if ! printf '%s\n' "$FW_RULES" | grep -qx -- "-P OUTPUT DROP"; then
          FW_INTACT=0
          REASON="gluetun OUTPUT policy is not DROP — the kill switch is not enforcing"
        fi

        # Any destination-scoped ACCEPT out eth0 must name an allowed target.
        # Rules with no -d (lo, conntrack, tun0) are not destination-scoped and
        # are excluded by the -o eth0 filter plus the empty-dest skip.
        while read -r rule; do
          [ -z "$rule" ] && continue
          dest=$(printf '%s\n' "$rule" | awk '{for(i=1;i<=NF;i++) if($i=="-d") print $(i+1)}')
          [ -z "$dest" ] && continue
          # The WireGuard endpoint /32 is legitimate and changes on every server
          # rotation, so it is identified by shape (udp dport 51820) rather than
          # by address.
          printf '%s\n' "$rule" | grep -q -- "--dport 51820" && continue
          ok=0
          for allowed in ${lib.concatStringsSep " " allowedOutboundDests}; do
            [ "$dest" = "$allowed" ] && ok=1
          done
          if [ "$ok" -eq 0 ]; then
            FW_INTACT=0
            REASON="unexpected egress permitted to $dest — the gluetun firewall has been widened beyond the declared allowlist"
          fi
        done < <(printf '%s\n' "$FW_RULES" | grep -- "-j ACCEPT" | grep -- "-o eth0")
      fi

      VERDICT_BAD=0
      if [ "$LEAK" -eq 1 ] || [ "$FW_INTACT" -eq 0 ]; then VERDICT_BAD=1; fi

      # ---- two-strike confirmation ------------------------------------------
      # One bad read must not take down the media stack; two consecutive ones
      # five minutes apart are not a transient.
      STRIKES=$(cat "$STRIKE_FILE" 2>/dev/null || echo 0)
      if [ "$VERDICT_BAD" -eq 1 ]; then
        STRIKES=$(( STRIKES + 1 ))
      else
        STRIKES=0
      fi
      echo "$STRIKES" > "$STRIKE_FILE"

      write_metrics 0 "$TUNNEL_UP" "$LEAK" "$FW_INTACT"

      if [ "$VERDICT_BAD" -eq 1 ] && [ "$STRIKES" -ge 2 ]; then
        echo "VPN LEAK CONFIRMED: $REASON" >&2
        printf '%s\n%s\n' "$(date -Is)" "$REASON" > "$LATCH"

        for unit in ${lib.concatStringsSep " " stackUnits}; do
          systemctl stop "$unit" || true
        done

        write_metrics 1 0 "$LEAK" "$FW_INTACT"

        curl -s --connect-timeout 5 --max-time 30 --retry 3 --retry-delay 10 \
          --retry-all-errors \
          -H 'Title: VPN LEAK - arr stack disabled' \
          -H 'Priority: 5' \
          -H 'Tags: rotating_light' \
          -d "pirateship: $REASON

The arr stack has been STOPPED and latched off. It will not restart on reboot,
deploy or auto-upgrade until the latch is cleared:

  sudo rm ${latchFile}
  sudo systemctl start ${lib.concatStringsSep " " (lib.reverseList stackUnits)}" \
          "${ntfyUrl}" || true
      elif [ "$VERDICT_BAD" -eq 1 ]; then
        echo "Possible VPN leak (strike $STRIKES/2): $REASON" >&2
      fi

      exit 0
    '';
  };

  systemd.timers.vpn-leak-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "5min";
      AccuracySec = "30s";
    };
  };

  # The latch. podman-gluetun refuses to start while the file exists, and every
  # arr container has Requires=podman-gluetun.service, so the whole stack stays
  # down with it. Failing here also trips the existing UnitFailed alert, which
  # is the intended noise level for "your VPN leaked".
  systemd.services.podman-gluetun.serviceConfig.ExecStartPre = lib.mkBefore [
    "${pkgs.writeShellScript "vpn-killswitch-latch" ''
      if [ -e "${latchFile}" ]; then
        echo "REFUSING TO START: the VPN kill switch is latched." >&2
        echo "Reason recorded at ${latchFile}:" >&2
        cat "${latchFile}" >&2
        echo "Clear with: sudo rm ${latchFile}" >&2
        exit 1
      fi
    ''}"
  ];

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 root root -"
  ];

  # Deliberately NOT added to homelab.postUpgradeCheck.services: that check
  # asserts `systemctl is-active`, which a completed oneshot never satisfies.
  # The detector's own liveness is covered by VpnLeakCheckStale in
  # modules/grafana.nix, which is the right instrument for a periodic job.
}
