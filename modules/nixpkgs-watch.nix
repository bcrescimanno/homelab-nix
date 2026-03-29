# modules/nixpkgs-watch.nix — Watch for nixpkgs package version conditions
#
# Runs daily on rivendell. When a watched condition is met, sends a single
# ntfy notification and records that it fired (so it doesn't repeat).
#
# Current watch: music-assistant >= 2.8 in nixos-unstable.
# We're pinned to nixpkgs-unstable to get libraop (AirPlay). Once MA 2.8
# lands in nixos-unstable we can switch back:
#   1. Change flake.nix: nixpkgs-unstable → nixos-unstable
#   2. nix flake update nixpkgs
#   3. deploy rivendell mirkwood pirateship

{ config, pkgs, lib, ... }:

let
  checkScript = pkgs.writeShellScript "nixpkgs-watch" ''
    set -euo pipefail

    STATE_FILE="/var/lib/nixpkgs-watch/ma-28-notified"

    # Already fired — nothing to do until the file is manually removed.
    [ -f "$STATE_FILE" ] && exit 0

    # Get the current nixos-unstable channel revision.
    REV=$(${pkgs.curl}/bin/curl -sf --connect-timeout 10 --max-time 30 \
      https://channels.nixos.org/nixos-unstable/git-revision) || exit 0
    [ -z "$REV" ] && exit 0

    # Fetch music-assistant package.nix at that revision.
    PKG_NIX=$(${pkgs.curl}/bin/curl -sf --connect-timeout 10 --max-time 30 \
      "https://raw.githubusercontent.com/NixOS/nixpkgs/$REV/pkgs/by-name/mu/music-assistant/package.nix") || exit 0
    [ -z "$PKG_NIX" ] && exit 0

    # Extract version string (e.g. version = "2.8.0" → 2.8.0).
    VERSION=$(echo "$PKG_NIX" | ${pkgs.gnugrep}/bin/grep -oP 'version = "\K[^"]+' | head -1)
    [ -z "$VERSION" ] && exit 0

    # Parse major and minor from the version string.
    MAJOR=$(echo "$VERSION" | cut -d. -f1)
    MINOR=$(echo "$VERSION" | cut -d. -f2)

    # Check if version >= 2.8.
    if ! ( [ "$MAJOR" -gt 2 ] || ( [ "$MAJOR" -eq 2 ] && [ "$MINOR" -ge 8 ] ) ); then
      exit 0
    fi

    # Condition met — notify once.
    ${pkgs.curl}/bin/curl -s \
      --connect-timeout 5 --max-time 30 --retry 3 --retry-delay 10 --retry-all-errors \
      -H 'Title: Switch nixpkgs back to nixos-unstable' \
      -H 'Priority: 3' \
      -H 'Tags: tada' \
      -d "music-assistant $VERSION is in nixos-unstable (''${REV:0:8}). Edit flake.nix: nixpkgs-unstable → nixos-unstable, then nix flake update nixpkgs." \
      http://127.0.0.1:2586/homelab

    # Record that we fired so we don't notify again.
    touch "$STATE_FILE"
  '';
in

{
  systemd.services.nixpkgs-watch = {
    description = "Check nixpkgs channels for watched package conditions";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = checkScript;
      StateDirectory = "nixpkgs-watch";
    };
  };

  systemd.timers.nixpkgs-watch = {
    description = "Daily nixpkgs package version watch";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "1h";
      Persistent = true; # Run immediately on boot if the last run was missed.
    };
  };
}
