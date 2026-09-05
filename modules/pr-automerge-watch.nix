# modules/pr-automerge-watch.nix — alert when a PR that should merge itself cannot
#
# Renovate opens every dependency PR in this repo with automerge armed
# (renovate.json arms lockFileMaintenance, the nix packageRule and the
# container-digest packageRule alike), so an open Renovate PR is either in
# flight or wedged. Until now nothing could tell those apart.
#
# THE GAP THIS CLOSES
#
# On 2026-08-29 the Saturday lockFileMaintenance PR (#627) opened at 22:14 PDT
# with automerge armed, and its aarch64 gate failed 47 seconds later — our own
# alertmanagerElmOverlay had become redundant, so its --replace-fail found
# nothing to replace. The PR sat blocked. At 04:02-05:01 the nightly upgrade ran
# on all four hosts, succeeded on all four, and deployed the same lock as the
# night before. Nothing was wrong with the upgrade; it faithfully deployed a main
# that had not moved.
#
# Every signal was green, and correctly so: backups fine, Gatus fine, upgrade
# fine. modules/flake-freshness.nix is the check aimed at this failure and it
# would have caught it — in ten days, which is the right threshold for the
# question it asks (are the RUNNING inputs stale) and far too slow for this one.
#
# The two are complements, deliberately. flake-freshness asks about the running
# system and so catches every route to staleness including Renovate dying
# entirely; its own header explains why it is not gated on PR state. This asks
# the narrower, faster question: is something armed to merge unable to? A blocked
# lock PR is visible here within the hour, which is inside the ~5h46m a Saturday
# lock PR has between opening and the nightly upgrade window.
#
# WHY THE SIGNAL IS STATE, NOT AGE
#
# "Open more than N hours" needs an N above a legitimate build. renovate.json
# records the measurement: a real nixpkgs bump costs 42 min on rivendell's
# aarch64 runner. Any N comfortably above that is also above the 5h46m window,
# so an age-only rule would have reported #627 after the hosts had already
# missed it. Age is therefore the backstop; the signal is a terminal state — a
# failed required check, a merge conflict, checks that never started, or a
# Renovate PR whose automerge was never armed at all. See the docstring in
# pr-automerge-watch.py for each case and how it is distinguished from "slow".
#
# UNKNOWN IS NOT CLEAN
#
# Inherited from flake-freshness, which exists because nixpkgs-watch.nix
# swallowed a 302 and reported success for months. A failed fetch, a failed
# per-PR lookup, an undelivered ntfy push, or GitHub's asynchronously computed
# mergeable_state coming back null are each reported as UNKNOWN and never folded
# into "nothing stuck". Such a run exits non-zero, so OnFailure fires.
#
# NOT COVERED, ON PURPOSE: a timer that stops firing altogether is not detected
# here. OnFailure catches a run that fails, not a run that never happens. That
# matches modules/flake-freshness.nix, which is also unstamped; the restic
# dead-man's switch in backup.nix covers backups and upgrades only. If watchers
# are ever added to that switch, add both together.
#
# Runs on rivendell because that is where ntfy is, alongside flake-freshness.
# The repo is public so the API is read unauthenticated — no token to expire,
# one less silent failure mode.

{ config, pkgs, lib, ... }:

let
  ntfyUrl = "http://10.0.1.9:2586/homelab";
  host = config.networking.hostName;
in

{
  systemd.services.pr-automerge-watch = {
    description = "Alert when an automerge-armed PR cannot merge";
    # Timer-driven oneshot; see modules/music-sync.nix for why activation must
    # not start it. Its only legitimate trigger is the timer.
    restartIfChanged = false;
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "10m";
      StateDirectory = "pr-automerge-watch";
      ExecStart = "${pkgs.python3}/bin/python3 ${./pr-automerge-watch.py}";
      # Hardening: this only reads a public HTTP API and writes its own
      # StateDirectory.
      DynamicUser = false;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
    };

    environment = {
      PR_WATCH_REPO = "bcrescimanno/homelab-nix";
      PR_WATCH_NTFY = ntfyUrl;
    };

    unitConfig.OnFailure = "pr-automerge-watch-notify-failure.service";
  };

  systemd.services.pr-automerge-watch-notify-failure = {
    description = "Notify ntfy that the PR automerge watch failed";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = ''
        ${pkgs.curl}/bin/curl -s --connect-timeout 5 --max-time 30 \
          --retry 3 --retry-delay 10 --retry-all-errors \
          -H 'Title: PR automerge watch FAILED' \
          -H 'Priority: 3' \
          -H 'Tags: warning' \
          -d '${host} could not determine whether any automerge PR is stuck — check journalctl -u pr-automerge-watch' \
          ${ntfyUrl}
      '';
    };
  };

  systemd.timers.pr-automerge-watch = {
    description = "Hourly check for stuck automerge PRs";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Hourly: a lock PR opens ~22:14 PDT and the nightly upgrade starts 04:02,
      # so hourly puts a terminal failure in front of us with hours to spare.
      OnCalendar = "hourly";
      RandomizedDelaySec = "5m";
      Persistent = true;
    };
  };
}
