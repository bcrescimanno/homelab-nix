# modules/vpn-port-reachability.nix — detect and heal a forwarded port that
# exists but cannot be reached from the internet.
#
# THE GAP THIS FILLS. Three things already watch this stack and all three were
# green through a full day of the tracker being unable to connect:
#
#   * `gluetun-watchdog` (modules/arr-stack.nix) only fires when the port FILE
#     is empty or zero. The file said 39359 all day and was rewritten happily
#     every five minutes — the watchdog had nothing to complain about.
#   * `qbittorrent-port-sync` only asserts that qBittorrent's listen_port
#     equals the number in that file. It did, exactly as designed.
#   * `vpn-leak-check` (modules/vpn-killswitch.nix) asks whether traffic is
#     ESCAPING the tunnel. Nothing was.
#
# Every one of those is an INSIDE-OUT check: they confirm our own components
# agree with each other. None of them ever asks the only question a private
# tracker cares about — can someone on the internet actually open a connection
# to us. That question can only be answered from outside the tunnel.
#
# WHAT ACTUALLY BROKE (2026-09-15). ProtonVPN servers have more than one public
# address. NAT-PMP bound the forward to 146.70.194.59 while ordinary outbound
# traffic from the netns was NATed to 146.70.194.57. Tracker announces are
# plain HTTPS from an ephemeral port, so Redacted recorded .57 and probed
# .57:39359 — which times out. Inbound BitTorrent on .59:39359 was working the
# entire time (21 live peers, 225 KB/s up), which is exactly why nothing
# noticed. Measured both ways: a BitTorrent handshake to .59 completed and the
# same handshake to .57 timed out.
#
# Which of a server's addresses you get is luck of the draw on each reconnect,
# so this WILL recur — including on the nightly auto-upgrade restart.
#
# THE PROBE. From the pirateship HOST, outside the netns, open a TCP connection
# to <netns egress IP>:<forwarded port>. The packet leaves over the WAN, reaches
# the Proton server, and comes back down the tunnel — the same path a peer or a
# tracker takes. Verified working from pirateship itself on 2026-09-15 before
# this module was written; the hairpin is real, not theoretical.
#
# A successful TCP connect is proof the forward maps to our listener: Proton
# does not answer on ports it has not forwarded, so a SYN that gets an ACK got
# one from qBittorrent.
#
# Deliberately probing the EGRESS address rather than whatever address the
# forward happens to live on. The egress address is the one trackers record, so
# it is the one that has to answer. Probing the "right" address would report
# healthy during precisely the outage this exists to catch.
#
# POSITIVE SIGNAL ONLY — the same rule as modules/vpn-killswitch.nix, for the
# same reason. Restarting the stack is disruptive, so it happens only on
# evidence that the port is unreachable, never on absence of evidence. Each of
# these is UNKNOWN and explicitly NOT a strike:
#
#   * port file empty        → gluetun-watchdog's case, let it own the restart
#   * netns has no internet  → VpnTunnelDown's case, a restart would be noise
#   * qBittorrent not bound  → qbittorrent-port-sync's case, gluetun is fine
#   * kill switch latched    → the stack is intentionally down, do not fight it
#   * gluetun started < 15m  → still settling, or something else just restarted
#                              it; probing now would fail for innocent reasons
#
# Only "tunnel up, port present, listener bound, and the connect still fails"
# counts. Three consecutive such verdicts ten minutes apart are required before
# healing, so a transient WAN blip cannot bounce the media stack.
#
# THE HEAL is a gluetun restart, which re-runs NAT-PMP and re-rolls the server.
#
# `systemctl restart podman-gluetun` DOES bring the consumers back on its own —
# measured 2026-09-15, all six restarted within 7s of gluetun without being
# named. Requires= propagates a restart downward even though it is not
# PartOf=/BindsTo=. The healer still verifies each one afterwards and starts
# any that is not active: that is a no-op in the normal case and catches the
# one it does not cover, a consumer that failed to start for its own reasons
# (image pull, a wedged preStart) and would otherwise sit dead until a human
# noticed the downloads had stopped.
#
# BUDGET. Healing is capped at 3 attempts per rolling 24h with a 60-minute
# cooldown between them (the `maxHeals` / `cooldownSec` bindings below are the
# authority; these numbers are prose). If the cap is reached and the port is
# still unreachable, the module STOPS healing and sends a high-priority push:
# three different Proton servers failing in a row is not server roulette, it is
# something a restart cannot fix, and continuing to bounce the stack every hour
# would only make the problem harder to see. The budget clears itself on the
# first successful probe.
#
# Metrics go to node_exporter's textfile collector and are alerted on in the
# `vpn` rule group in modules/grafana.nix. As with vpn-leak-check, the
# staleness metric matters as much as the reachability one: a prober that
# silently died looks exactly like a port that is fine.

{ config, pkgs, lib, ... }:

let
  stateDir   = "/var/lib/vpn-port-reachability";
  metricFile = "/var/lib/prometheus-textfiles/vpn_port_reachability.prom";

  # The kill switch's latch, owned by modules/vpn-killswitch.nix. If this
  # exists the stack is intentionally down and must not be restarted here.
  latchFile  = "/var/lib/vpn-killswitch/tripped";

  portFile   = "/var/lib/gluetun/tmp/forwarded_port";

  # Literal IP, not `rivendell`: rivendell is also the DNS server, and a push
  # that says "your networking is broken" should not itself depend on name
  # resolution. Same address modules/vpn-killswitch.nix uses.
  ntfyUrl    = "http://10.0.1.9:2586/homelab";

  # Consumers of gluetun's netns, in the order they should be brought back up.
  # gluetun itself is restarted separately and is not in this list.
  consumerUnits = [
    "podman-qbittorrent" "podman-sabnzbd"  "podman-radarr"
    "podman-sonarr"      "podman-prowlarr" "podman-lidarr"
  ];

  strikesToHeal = 3;       # 3 verdicts x 10min timer = 30min of confirmed loss
  settleSec     = 900;     # 15min: do not judge a freshly started tunnel
  cooldownSec   = 3600;    # 1h minimum between heal attempts
  maxHeals      = 3;       # per rolling 24h, then hand it to a human
  healWindowSec = 86400;
in
{
  systemd.services.vpn-port-reachability = {
    description = "Verify the gluetun forwarded port is reachable from the internet; restart gluetun if it is not";

    # Timer-driven oneshot. restartIfChanged only covers ACTIVE units and a
    # timer oneshot is inactive, so X-OnlyManualStart is what actually stops
    # switch-to-configuration starting it mid-activation — which would fail the
    # deploy. See modules/music-sync.nix for the full why.
    restartIfChanged = false;
    unitConfig.X-OnlyManualStart = true;

    after = [ "podman-gluetun.service" "network-online.target" ];
    wants = [ "network-online.target" ];

    path = with pkgs; [ podman curl coreutils gnugrep gawk systemd netcat-gnu ];

    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "vpn-port-reachability";
    };

    # Deliberately NOT `set -e`: a failed probe must fall through to the UNKNOWN
    # path and still publish metrics, not abort the unit. A failing unit here
    # would trip the UnitFailed alert on every transient network blip.
    script = ''
      set -uo pipefail

      STRIKE_FILE="${stateDir}/strikes"
      HEALS_FILE="${stateDir}/heals"
      GAVEUP_FILE="${stateDir}/gave-up"

      NOW=$(date +%s)

      # $1 reachable  $2 unknown  $3 port  $4 heals_in_window
      write_metrics() {
        [ -d /var/lib/prometheus-textfiles ] || return 0
        tmp=$(mktemp -p /var/lib/prometheus-textfiles) || return 0
        {
          printf '# HELP vpn_port_reachable Forwarded port answers a TCP connect from outside the tunnel\n'
          printf '# TYPE vpn_port_reachable gauge\n'
          printf 'vpn_port_reachable %s\n' "$1"
          printf '# HELP vpn_port_reachability_unknown Probe could not reach a verdict this run\n'
          printf '# TYPE vpn_port_reachability_unknown gauge\n'
          printf 'vpn_port_reachability_unknown %s\n' "$2"
          printf '# HELP vpn_port_forwarded The port gluetun currently has forwarded\n'
          printf '# TYPE vpn_port_forwarded gauge\n'
          printf 'vpn_port_forwarded %s\n' "$3"
          printf '# HELP vpn_port_heals_24h Gluetun restarts this module performed in the last 24h\n'
          printf '# TYPE vpn_port_heals_24h gauge\n'
          printf 'vpn_port_heals_24h %s\n' "$4"
          printf '# HELP vpn_port_heal_exhausted Heal budget spent with the port still unreachable\n'
          printf '# TYPE vpn_port_heal_exhausted gauge\n'
          printf 'vpn_port_heal_exhausted %s\n' "$([ -e "$GAVEUP_FILE" ] && echo 1 || echo 0)"
          printf '# HELP vpn_port_check_timestamp_seconds Unix time of the last completed reachability check\n'
          printf '# TYPE vpn_port_check_timestamp_seconds gauge\n'
          printf 'vpn_port_check_timestamp_seconds %s\n' "$NOW"
        } > "$tmp"
        chmod 0644 "$tmp"
        mv "$tmp" "${metricFile}"
      }

      # Heals recorded inside the rolling window, one epoch timestamp per line.
      heals_in_window() {
        [ -e "$HEALS_FILE" ] || { echo 0; return; }
        awk -v now="$NOW" -v w="${toString healWindowSec}" \
          '$1 ~ /^[0-9]+$/ && (now - $1) < w { n++ } END { print n+0 }' "$HEALS_FILE"
      }

      HEALS=$(heals_in_window)

      # UNKNOWN: publish, keep strikes where they are, and stop. Used for every
      # condition another unit owns — see the header for the full list.
      unknown() {
        echo "UNKNOWN: $1" >&2
        write_metrics 0 1 "''${PORT:-0}" "$HEALS"
        exit 0
      }

      PORT=0

      # ---- preconditions: every one of these belongs to somebody else -------
      [ -e "${latchFile}" ] && unknown "VPN kill switch is latched — the stack is intentionally down"

      [ "$(systemctl is-active podman-gluetun)" = "active" ] \
        || unknown "podman-gluetun is not active"

      # A tunnel that came up seconds ago has not finished NAT-PMP, and a
      # restart from gluetun-watchdog or a deploy lands here too. Probing now
      # would fail for reasons that are nobody's fault.
      STARTED=$(date -d "$(systemctl show podman-gluetun -p ActiveEnterTimestamp --value)" +%s 2>/dev/null || echo 0)
      if [ "$STARTED" -gt 0 ] && [ $(( NOW - STARTED )) -lt ${toString settleSec} ]; then
        # Fresh tunnel, fresh evaluation.
        echo 0 > "$STRIKE_FILE"
        unknown "gluetun started $(( NOW - STARTED ))s ago — inside the ${toString settleSec}s settle window"
      fi

      PORT=$(tr -d '[:space:]' < "${portFile}" 2>/dev/null || true)
      case "$PORT" in
        ""|*[!0-9]*) PORT=0 ;;
      esac
      [ "$PORT" -eq 0 ] && unknown "no forwarded port in ${portFile} — gluetun-watchdog owns this case"

      # Tunnel reachability. If the netns cannot reach the internet at all then
      # the port being unreachable tells us nothing new, and VpnTunnelDown is
      # the alert that should speak.
      EGRESS=$(timeout 25 podman exec gluetun wget -qO- -T 15 https://api.ipify.org 2>/dev/null || true)
      case "$EGRESS" in
        ""|*[!0-9.]*) EGRESS="" ;;
      esac
      [ -z "$EGRESS" ] && unknown "netns has no internet egress — VpnTunnelDown owns this case"

      # If qBittorrent is not bound to the forwarded port, restarting gluetun
      # would re-roll the port and fix nothing. That is port-sync's job.
      #
      # Captured to a variable and grepped separately rather than piped, and
      # that is NOT stylistic. `podman exec ... | grep -q` under `pipefail` is
      # a race: grep -q exits the moment it matches, podman takes SIGPIPE and
      # dies 141, and pipefail hands the pipeline that 141 even though the
      # match succeeded. Measured 2026-09-15 — 6 of the first 8 runs returned
      # 141 with pipefail on, 0 of 20 with the capture form. Piped, this check
      # reports "not listening" at random and every one of those is a false
      # UNKNOWN that silently starves the strike counter during a real outage.
      LISTENERS=$(timeout 15 podman exec gluetun sh -c "netstat -tuln 2>/dev/null" || true)
      if ! printf '%s\n' "$LISTENERS" | grep -q ":$PORT "; then
        unknown "qBittorrent is not listening on $PORT — qbittorrent-port-sync owns this case"
      fi

      # ---- the probe: from the HOST, outside the tunnel ---------------------
      # Three quick attempts so a single dropped SYN is not a strike on its own.
      REACHABLE=0
      for attempt in 1 2 3; do
        if nc -z -w 8 "$EGRESS" "$PORT" 2>/dev/null; then
          REACHABLE=1
          break
        fi
      done

      if [ "$REACHABLE" -eq 1 ]; then
        # Success clears everything, including a spent budget: whatever was
        # wrong is over, and the next incident deserves a full set of attempts.
        echo 0 > "$STRIKE_FILE"
        rm -f "$GAVEUP_FILE"
        write_metrics 1 0 "$PORT" "$HEALS"
        exit 0
      fi

      STRIKES=$(cat "$STRIKE_FILE" 2>/dev/null || echo 0)
      case "$STRIKES" in ""|*[!0-9]*) STRIKES=0 ;; esac
      STRIKES=$(( STRIKES + 1 ))
      echo "$STRIKES" > "$STRIKE_FILE"

      write_metrics 0 0 "$PORT" "$HEALS"

      echo "Forwarded port $PORT unreachable at $EGRESS (strike $STRIKES/${toString strikesToHeal})" >&2

      [ "$STRIKES" -lt ${toString strikesToHeal} ] && exit 0

      # ---- confirmed unreachable; decide whether we may heal ----------------
      if [ -e "$GAVEUP_FILE" ]; then
        echo "Heal budget already exhausted — not restarting. Waiting for a human." >&2
        exit 0
      fi

      LAST_HEAL=$(tail -n1 "$HEALS_FILE" 2>/dev/null || echo 0)
      case "$LAST_HEAL" in ""|*[!0-9]*) LAST_HEAL=0 ;; esac
      if [ "$LAST_HEAL" -gt 0 ] && [ $(( NOW - LAST_HEAL )) -lt ${toString cooldownSec} ]; then
        echo "Cooldown: last heal $(( NOW - LAST_HEAL ))s ago, need ${toString cooldownSec}s" >&2
        exit 0
      fi

      if [ "$HEALS" -ge ${toString maxHeals} ]; then
        touch "$GAVEUP_FILE"
        write_metrics 0 0 "$PORT" "$HEALS"
        echo "Heal budget exhausted (${toString maxHeals} in 24h) — giving up" >&2
        curl -s --connect-timeout 5 --max-time 30 --retry 3 --retry-delay 10 \
          --retry-all-errors \
          -H 'Title: VPN port forwarding unfixable - manual action needed' \
          -H 'Priority: 5' \
          -H 'Tags: rotating_light' \
          -d "pirateship: forwarded port $PORT is still unreachable at $EGRESS after ${toString maxHeals} gluetun restarts in 24h.

Automatic healing has STOPPED so the stack is not bounced indefinitely. Private
trackers will report this client as unconnectable until it is resolved.

Three different ProtonVPN servers failing in a row is not the usual exit-IP
mismatch. Check whether ProtonVPN port forwarding is enabled on the account and
whether the endpoint is a port-forward-capable server:

  journalctl -u vpn-port-reachability -n 50
  sudo podman logs --since 1h gluetun | grep -i 'port forward'

Healing resumes automatically once a probe succeeds." \
          "${ntfyUrl}" || true
        exit 0
      fi

      # ---- heal -------------------------------------------------------------
      echo "$NOW" >> "$HEALS_FILE"
      HEALS=$(( HEALS + 1 ))
      echo 0 > "$STRIKE_FILE"

      echo "Restarting gluetun to re-roll the forwarded port (heal $HEALS/${toString maxHeals} in 24h)" >&2
      systemctl restart podman-gluetun || true

      # The restart above already brings these back (Requires= propagates it;
      # measured 2026-09-15). This is the safety net for the case it does not
      # cover: a consumer that failed to start on its own account. Give the
      # tunnel a moment first so their preStart hooks see a live tun0.
      sleep 30
      for unit in ${lib.concatStringsSep " " consumerUnits}; do
        if [ "$(systemctl is-active "$unit")" != "active" ]; then
          echo "Consumer $unit did not come back — starting it" >&2
          systemctl start "$unit" || true
        fi
      done

      # port-sync races qBittorrent's startup on a gluetun restart and then
      # waits out its 5-minute inotify timeout. Nudging it closes that gap.
      systemctl restart qbittorrent-port-sync || true

      write_metrics 0 0 "$PORT" "$HEALS"

      curl -s --connect-timeout 5 --max-time 30 --retry 3 --retry-delay 10 \
        --retry-all-errors \
        -H 'Title: VPN forwarded port unreachable - restarted gluetun' \
        -H 'Priority: 4' \
        -H 'Tags: warning' \
        -d "pirateship: port $PORT was not reachable at $EGRESS from outside the tunnel.

Restarted gluetun to re-roll the ProtonVPN server and port (heal $HEALS of ${toString maxHeals} in 24h).
The next check in 10 minutes will confirm whether the new server works.

Usual cause: the Proton server forwards the port on a different public address
than the one outbound traffic is NATed to, so trackers probe an address that
never answers." \
        "${ntfyUrl}" || true

      exit 0
    '';
  };

  systemd.timers.vpn-port-reachability = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Later than vpn-leak-check's 3min so a boot does not run both probes
      # into the same cold tunnel.
      OnBootSec = "12min";
      OnUnitActiveSec = "10min";
      AccuracySec = "30s";
    };
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 root root -"
  ];

  # Deliberately NOT in homelab.postUpgradeCheck.services: that asserts
  # `systemctl is-active`, which a completed oneshot never satisfies. This
  # prober's own liveness is covered by VpnPortCheckStale in modules/grafana.nix.
}
