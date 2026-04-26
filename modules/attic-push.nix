# modules/attic-push.nix — Nix post-build hook that pushes store paths to attic.
#
# Imported by modules/base.nix so it applies to all hosts. The hook reads
# /run/secrets/attic_push_token (declared per-host via sops.secrets), exits
# gracefully if the token is absent or not yet provisioned.
#
# Push counters are written to /var/lib/prometheus-textfiles/attic_push.prom
# for consumption by node_exporter's textfile collector (configured in
# modules/monitoring.nix).

{ pkgs, ... }:

{
  # Attic binary cache — served from orthanc as cache.theshire.io via Caddy on rivendell.
  # The post-build hook pushes every built path to the cache so subsequent
  # hosts (and future upgrades) can fetch instead of rebuilding.
  #
  # The hook exits gracefully if attic_push_token is not yet provisioned —
  # this lets all hosts deploy before the cache is fully set up.
  nix.settings.extra-substituters = [ "https://cache.theshire.io/nixpkgs" ];
  nix.settings.extra-trusted-public-keys = [ "nixpkgs:4zoHH4lPBJuJfPmH0/FjKl5yIYfG0yCZc39m492t+jM=" ];

  nix.settings.post-build-hook = toString (pkgs.writeShellScript "attic-push" ''
    set -f  # Disable glob expansion on $OUT_PATHS

    [ -f /run/secrets/attic_push_token ] || exit 0
    [ -n "$OUT_PATHS" ] || exit 0

    ATTIC_TOKEN=$(cat /run/secrets/attic_push_token)
    # Valid JWTs always start with 'eyJ' — skip if token is a placeholder.
    case "$ATTIC_TOKEN" in eyJ*) ;; *) exit 0 ;; esac

    # attic reads config from $HOME/.config/attic/config.toml.
    # Use a temp HOME so we don't pollute /root/.config.
    ATTIC_HOME=$(mktemp -d --tmpdir attic.XXXXXXXX)
    trap 'rm -rf "$ATTIC_HOME"' EXIT
    mkdir -p "$ATTIC_HOME/.config/attic"
    printf '[servers.homelab]\nendpoint = "https://cache.theshire.io/"\ntoken = "%s"\n' \
      "$ATTIC_TOKEN" > "$ATTIC_HOME/.config/attic/config.toml"

    # Push one path at a time — the attic client (0-unstable-2025-09-24) has a
    # panic_in_cleanup bug in Pusher::worker that triggers when batching multiple
    # paths. Pushing serially avoids it. Remove the loop once attic is fixed upstream.
    METRIC_FILE="/var/lib/prometheus-textfiles/attic_push.prom"
    PUSH_SUCCESS=0
    PUSH_FAILURE=0

    for path in $OUT_PATHS; do
      if HOME="$ATTIC_HOME" ${pkgs.attic-client}/bin/attic push homelab:nixpkgs "$path"; then
        PUSH_SUCCESS=$((PUSH_SUCCESS + 1))
      else
        echo "attic-push: push failed for $path (non-fatal)" >&2
        PUSH_FAILURE=$((PUSH_FAILURE + 1))
      fi
    done

    # Append to running counters atomically — read → increment → write.
    if [ -d /var/lib/prometheus-textfiles ]; then
      PREV_SUCCESS=$(grep -m1 '^attic_push_success_total ' "$METRIC_FILE" 2>/dev/null | awk '{print $2}' || echo 0)
      PREV_FAILURE=$(grep -m1 '^attic_push_failure_total ' "$METRIC_FILE" 2>/dev/null | awk '{print $2}' || echo 0)
      TOTAL_SUCCESS=$((PREV_SUCCESS + PUSH_SUCCESS))
      TOTAL_FAILURE=$((PREV_FAILURE + PUSH_FAILURE))
      METRIC_TMP=$(mktemp -p /var/lib/prometheus-textfiles)
      printf '# HELP attic_push_success_total Attic store paths pushed successfully\n' > "$METRIC_TMP"
      printf '# TYPE attic_push_success_total counter\n'                               >> "$METRIC_TMP"
      printf 'attic_push_success_total %s\n' "$TOTAL_SUCCESS"                          >> "$METRIC_TMP"
      printf '# HELP attic_push_failure_total Attic store paths that failed to push\n' >> "$METRIC_TMP"
      printf '# TYPE attic_push_failure_total counter\n'                               >> "$METRIC_TMP"
      printf 'attic_push_failure_total %s\n' "$TOTAL_FAILURE"                          >> "$METRIC_TMP"
      mv "$METRIC_TMP" "$METRIC_FILE"
    fi
  '');
}
