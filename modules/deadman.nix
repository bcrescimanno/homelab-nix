# modules/deadman.nix — external dead-man switch for the notification path.
#
# THE HOLE THIS FILLS
#
# Traced 2026-09-19: every alert this lab can raise terminates at ONE host.
# Prometheus and Alertmanager run on mirkwood, but Alertmanager's only receiver
# posts to http://10.0.1.9:2586 — rivendell's ntfy. Gatus runs on rivendell, so
# it cannot report the death of its own host. reboot-policy, post-upgrade-check,
# the restic OnFailure hooks, flake-freshness and pr-automerge-watch all push to
# rivendell:2586 as well.
#
# So if rivendell is down — or if ntfy alone is broken while rivendell is
# otherwise fine — the lab goes silent, INCLUDING the alert that would say so.
# That is the structural version of every silent failure already on record.
#
# -----------------------------------------------------------------------------
# WHY THE HEARTBEAT IS NOT A LIVENESS PING
#
# The obvious version of this module is a timer that curls healthchecks.io
# unconditionally. That only catches a dead host or a dead house, and it leaves
# the actual reported gap wide open: mirkwood with a healthy NIC happily pings
# green while ntfy on rivendell is crashed, and the phone stays quiet.
#
# So the ping is EARNED, not scheduled. Each run publishes a message carrying a
# fresh random token to a dedicated ntfy topic on rivendell, then reads it back
# through ntfy's poll API and checks the token came out the other side. Only a
# verified round-trip pings hc-ping.com. That covers rivendell being down, ntfy
# being crashed, ntfy answering but not storing, and a LAN partition between
# this host and rivendell — all of which are today invisible.
#
# The probe topic is deliberately NOT `homelab`: nothing is subscribed to it, so
# a probe every 15 minutes never reaches a phone. `Priority: min` is belt and
# braces on top of that.
#
# -----------------------------------------------------------------------------
# ONE CHECK PER HOST, ON PURPOSE
#
# mirkwood and orthanc each own their own healthchecks.io check and their own
# ping URL secret. Pointing both at a single shared check would let either host
# keep it green and mask the other's death. Separate checks make the signal
# read directly off the dashboard:
#
#   only mirkwood silent          -> mirkwood is the problem
#   only orthanc silent           -> orthanc is the problem
#   both fail, "round-trip"       -> rivendell or ntfy is the problem
#   both silent, no /fail         -> the house or its internet is gone
#
# rivendell needs no check of its own: its health IS the round-trip both other
# hosts measure. pirateship is covered by Gatus and Prometheus, which alert
# through ntfy — a path this module now verifies.
#
# -----------------------------------------------------------------------------
# WHAT EXIT STATUS MEANS HERE (it is not the usual convention)
#
# A failed round-trip exits ZERO. That is not sloppiness. The failure has
# already been reported out-of-band by POSTing to hc-ping.com/<uuid>/fail, and
# the only local notifier available is the very ntfy we just proved broken. A
# non-zero exit would add an OnFailure push into a black hole and a red unit
# that tells nobody anything.
#
# The unit exits NON-ZERO only when it could not reach hc-ping.com — a genuinely
# different failure, where the local path still works and is worth using. That
# case gets the OnFailure ntfy push below, so an internet blip arrives with
# local context instead of only as a mysterious external page.
#
# -----------------------------------------------------------------------------
# OUT-OF-BAND MEANS OUT-OF-BAND
#
# healthchecks.io is configured to alert via a PUBLIC ntfy.sh topic, not this
# lab's ntfy. That path shares no infrastructure with the thing it reports on,
# which is the entire point; routing it back through ntfy.theshire.io would
# rebuild the single point of failure one level up. The existing ntfy iOS app
# subscribes to it, so there is no second app.
#
# Residual gap, stated rather than hidden: this cannot test iOS push delivery
# for the self-hosted instance, which depends on ntfy's `upstream-base-url`
# relay through ntfy.sh (modules/ntfy.nix). If that relay breaks, ntfy still
# stores and serves messages, the round-trip still passes, and the phone still
# goes quiet. The mitigation is that healthchecks.io alerts do not traverse it.
#
# -----------------------------------------------------------------------------
# INTERACTION WITH LOAD SHEDDING AND REBOOTS — EXPECTED, NOT NOISE
#
# orthanc is the one shed host: it powers off 5 minutes into an outage, or below
# 50% charge (hosts/orthanc.nix). Its heartbeat stops with it, so `homelab-orthanc`
# WILL go red during any real outage. That is not a false alarm to tune out — a
# shed host does not come back on its own (it needs the wakeOnRestore magic
# packet, see the UPS section of CLAUDE.md), so a check that stays red after
# mains returns is precisely the signal that WoL did not fire. mirkwood never
# sheds, so its check stays the clean "is the house up" reading.
#
# Nightly reboots do not trip either check: Period 15 + Grace 25 tolerates 40
# minutes of silence and a reboot is minutes, plus `Persistent = true` fires a
# catch-up ping on boot.
#
# -----------------------------------------------------------------------------
# ONE-TIME SETUP AT HEALTHCHECKS.IO (free Hobbyist tier — 20 checks)
#
# This config cannot be expressed in Nix; it lives in the healthchecks.io UI.
# Recorded here so it is recoverable.
#
#   1. Create a project, then two checks:
#        homelab-mirkwood    Period 15 min   Grace 25 min
#        homelab-orthanc     Period 15 min   Grace 25 min
#      Period + Grace = 40 min, which tolerates exactly one missed ping (a
#      transient blip) and alerts on the second. Do not lower Grace below 2x
#      Period or a single dropped packet pages you.
#
#   2. Integrations -> ntfy:
#        Server   https://ntfy.sh          (PUBLIC — not ntfy.theshire.io)
#        Topic    a long, high-entropy name; the topic name IS the credential
#        Priority 5 (max) for "down", default for "up"
#      Subscribe the ntfy iOS app to that topic.
#
#   3. Copy each check's UUID ping URL (https://hc-ping.com/<uuid>) into the
#      matching host's sops file as `deadman_ping_url`.
#
# The upstream forwarding note: ntfy relays a tiny "poll request" to ntfy.sh for
# every published message on every topic, with no per-topic opt-out. Two hosts x
# 4 probes/hour adds 8/hour against a 720/hour sustained visitor budget — about
# 1%, measured against ntfy's documented token-bucket defaults (burst 60,
# replenish 1 per 5s). Raising the probe frequency materially would need that
# arithmetic redone before it is safe.
#
# -----------------------------------------------------------------------------
# AN UNPROVISIONED SWITCH MUST NOT LOOK LIKE A HEALTHY ONE
#
# Before the secret exists the script cannot ping anything, and it exits 0 so
# the hosts still deploy. Exiting quietly there would recreate the exact bug
# that killed modules/nixpkgs-watch.nix — a unit reporting success while
# checking nothing. So it also writes homelab_deadman_provisioned 0 to the
# node_exporter textfile collector, and modules/grafana.nix alerts on it. "I am
# not switched on" and "everything is fine" must never look the same.

{ config, pkgs, lib, ... }:

let
  host = config.networking.hostName;

  # rivendell by IP, never DNS — this is the path that has to work while the
  # lab is broken, and mirkwood IS the primary resolver. Same reasoning as
  # modules/nut-secondary.nix.
  ntfyBase = "http://10.0.1.9:2586";
  probeTopic = "deadman-probe";

  textfileDir = "/var/lib/prometheus-textfiles";

  deadmanScript = pkgs.writeShellScript "deadman-heartbeat" ''
    # No `set -e`: every failure here is handled explicitly and turned into
    # either an external /fail or a metric. An implicit abort would skip both.
    set -uo pipefail

    PATH=${lib.makeBinPath [ pkgs.curl pkgs.coreutils pkgs.gnugrep pkgs.gawk ]}

    PING_FILE=/run/secrets/deadman_ping_url
    METRICS=${textfileDir}/deadman.prom
    HOST=${host}

    # args: provisioned, roundtrip_ok, last_success_ts
    write_metrics() {
      [ -d ${textfileDir} ] || return 0
      tmp=$(mktemp -p ${textfileDir} deadman.XXXXXX) || return 0
      {
        echo "# HELP homelab_deadman_provisioned Whether the external dead-man switch ping URL is configured."
        echo "# TYPE homelab_deadman_provisioned gauge"
        echo "homelab_deadman_provisioned $1"
        echo "# HELP homelab_deadman_ntfy_roundtrip_ok Whether the last ntfy publish-and-read-back probe succeeded."
        echo "# TYPE homelab_deadman_ntfy_roundtrip_ok gauge"
        echo "homelab_deadman_ntfy_roundtrip_ok $2"
        echo "# HELP homelab_deadman_last_success_timestamp_seconds Unix time of the last fully successful heartbeat."
        echo "# TYPE homelab_deadman_last_success_timestamp_seconds gauge"
        echo "homelab_deadman_last_success_timestamp_seconds $3"
      } > "$tmp" && chmod 0644 "$tmp" && mv "$tmp" "$METRICS"
    }

    # Carry the last success forward across failing runs, so the freshness of
    # the heartbeat is readable from the metric alone.
    prev_success_ts() {
      ts=$(grep -m1 '^homelab_deadman_last_success_timestamp_seconds ' "$METRICS" 2>/dev/null | awk '{print $2}')
      case "$ts" in
        "" | *[!0-9]* ) echo 0 ;;
        * ) echo "$ts" ;;
      esac
    }

    PREV_TS=$(prev_success_ts)

    # -- Is the switch actually armed? ----------------------------------------
    if [ ! -s "$PING_FILE" ]; then
      echo "deadman: $PING_FILE is missing or empty — the EXTERNAL DEAD-MAN SWITCH IS NOT ACTIVE on $HOST." >&2
      echo "deadman: see the setup block in modules/deadman.nix; until then ntfy remains a sole dependency." >&2
      write_metrics 0 0 "$PREV_TS"
      exit 0
    fi

    PING_URL=$(tr -d '[:space:]' < "$PING_FILE")
    case "$PING_URL" in
      https://hc-ping.com/*) ;;
      *)
        echo "deadman: $PING_FILE does not hold an https://hc-ping.com/ URL — treating as unprovisioned." >&2
        write_metrics 0 0 "$PREV_TS"
        exit 0
        ;;
    esac

    # -- The round-trip: publish a token to ntfy, then read it back -----------
    round_trip() {
      token="deadman-$HOST-$(date +%s)-$RANDOM$RANDOM"

      curl -sS --fail --connect-timeout 5 --max-time 15 \
        -H 'Title: dead-man probe' \
        -H 'Priority: min' \
        -H 'Tags: robot' \
        -d "$token" \
        "${ntfyBase}/${probeTopic}" >/dev/null || return 1

      # ntfy acknowledges the publish before the message is necessarily
      # readable; a moment's settle keeps this from racing its own write.
      sleep 2

      # since=120s rather than the exact message id: we only care that OUR
      # token survived the store, and other hosts' probes inside the window are
      # harmless noise to grep past.
      curl -sS --fail --connect-timeout 5 --max-time 15 \
        "${ntfyBase}/${probeTopic}/json?poll=1&since=120s" \
        | grep -qF "$token" || return 1

      return 0
    }

    # One retry before declaring failure. ntfy's cache is in-memory and does not
    # survive a restart, so a probe that straddles an ntfy restart legitimately
    # loses its message. Retrying distinguishes that from ntfy being down.
    if round_trip; then
      RT_OK=1
    else
      echo "deadman: ntfy round-trip failed, retrying once in 20s" >&2
      sleep 20
      if round_trip; then RT_OK=1; else RT_OK=0; fi
    fi

    # -- Report outward -------------------------------------------------------
    if [ "$RT_OK" = 1 ]; then
      if curl -sS --fail --connect-timeout 10 --max-time 30 \
           --retry 2 --retry-delay 5 --retry-all-errors \
           "$PING_URL" >/dev/null; then
        write_metrics 1 1 "$(date +%s)"
        exit 0
      fi
      # Round-trip fine, hc-ping.com unreachable. The local path works, so say
      # so locally via OnFailure; the external check will also go red on its own
      # grace expiry, which is correct but contextless on its own.
      echo "deadman: ntfy round-trip OK but hc-ping.com is unreachable" >&2
      write_metrics 1 1 "$PREV_TS"
      exit 1
    fi

    # Round-trip failed: report it out-of-band immediately rather than waiting
    # out the grace period. Body stays terse — it leaves the premises.
    echo "deadman: ntfy round-trip FAILED — reporting to hc-ping.com/fail" >&2
    write_metrics 1 0 "$PREV_TS"

    curl -sS --fail --connect-timeout 10 --max-time 30 \
      --retry 2 --retry-delay 5 --retry-all-errors \
      -d "$HOST: ntfy round-trip to rivendell failed" \
      "$PING_URL/fail" >/dev/null || \
      echo "deadman: could not deliver /fail either; falling back to grace expiry" >&2

    # Exit 0 deliberately — see the header. The only local notifier is the ntfy
    # we just proved broken, so OnFailure would push into a black hole.
    exit 0
  '';
in

{
  # Absence is handled gracefully by the script (and alerted on via the
  # provisioned metric), so both hosts deploy fine before the account exists.
  sops.secrets.deadman_ping_url = { };

  systemd.services.deadman-heartbeat = {
    description = "External dead-man switch heartbeat (ntfy round-trip -> healthchecks.io)";

    # Timer oneshot: systemd must not start this during activation. It can exit
    # non-zero by design (hc-ping.com unreachable), and a unit that fails
    # mid-activation fails the whole deploy. restartIfChanged only covers ACTIVE
    # units and a timer oneshot is inactive, so X-OnlyManualStart is the marker
    # that actually holds. Same pattern as modules/pr-automerge-watch.nix.
    restartIfChanged = false;
    unitConfig = {
      X-OnlyManualStart = true;
      OnFailure = "deadman-heartbeat-notify-failure.service";
    };

    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "3m";
      # Writes only its own .prom file; reads one secret and two HTTP endpoints.
      DynamicUser = false;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      ReadWritePaths = [ textfileDir ];
      ExecStart = toString deadmanScript;
    };
  };

  # Fires ONLY for "could not reach hc-ping.com" — a round-trip failure exits 0
  # precisely so this does not push into a dead ntfy.
  systemd.services.deadman-heartbeat-notify-failure = {
    description = "Notify ntfy that the dead-man heartbeat could not reach healthchecks.io";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = ''
        ${pkgs.curl}/bin/curl -s --connect-timeout 5 --max-time 30 \
          --retry 3 --retry-delay 10 --retry-all-errors \
          -H 'Title: Dead-man switch cannot reach healthchecks.io' \
          -H 'Priority: 4' \
          -H 'Tags: warning' \
          -d '${host} verified ntfy is healthy but could not ping hc-ping.com. The external check will go red on grace expiry. Suspect the internet or healthchecks.io itself, not the lab.' \
          ${ntfyBase}/homelab
      '';
    };
  };

  systemd.timers.deadman-heartbeat = {
    description = "Dead-man switch heartbeat every 15 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 15 min against healthchecks.io Period 15 / Grace 25: one missed ping is
      # absorbed, two alert (~40 min). Randomized so the two hosts decorrelate
      # and never fail together merely for firing together.
      OnCalendar = "*:0/15";
      RandomizedDelaySec = "2m";
      # Ping promptly after a boot so a recovered host clears its check without
      # waiting out the next quarter hour.
      Persistent = true;
    };
  };
}
