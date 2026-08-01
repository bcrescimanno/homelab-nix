# modules/invidious.nix — Invidious: privacy-respecting YouTube frontend
#
# -----------------------------------------------------------------------------
# STATUS 2026-08-01: TRIAL, running SIDE BY SIDE with Piped.
#
# modules/piped.nix documents why Piped's playback is dead (YouTube PoToken/SABR
# defeating a dormant NewPipeExtractor). This module is the candidate
# replacement. Piped is deliberately left running and untouched — different
# ports, different vhost, different database — so the two can be compared on the
# same subscriptions before anything is removed. Retire Piped ONLY after
# playback here has been verified over several days; see the exit criteria at
# the bottom of this comment.
#
# -----------------------------------------------------------------------------
# CORRECTION TO THE EARLIER ASSESSMENT: this is NOT a fully-native replacement.
#
# The "replace 4 containers with a native service" framing in the piped.nix note
# was wrong on the one point that decides the whole thing. Invidious ALSO cannot
# play video on its own any more. Since 2025 it delegates all stream retrieval
# to `invidious-companion`, a separate Deno service that mints the po_token /
# visitor_data pair YouTube now demands. Without it Invidious loads, searches,
# and shows subscriptions — and every video fails. nixpkgs' own module test
# asserts exactly this log line:
#
#   nixos/tests/invidious.nix:145
#     "WARNING: Invidious companion is required to view and playback videos"
#
# And invidious-companion is NOT PACKAGED IN NIXPKGS (checked 2026-08-01: no
# package under pkgs/by-name, no option in services.invidious; the only hit in
# the entire tree is the assertion above). So it runs as a container here, and
# that is unavoidable short of packaging a Deno app ourselves.
#
# `services.invidious.sig-helper` is NOT the answer either — it is the previous
# generation of this mechanism, superseded upstream by companion, and nixpkgs
# carries it at 0-unstable-2025-07-23. Do not enable it expecting playback.
#
# What this migration actually buys, then, is 4 containers → 1, with the
# database and the application itself becoming native NixOS services. The
# postgres 16-alpine container that piped.nix flags as a principle violation
# goes away with Piped. That is a genuine improvement, just a smaller one than
# advertised — and the real reason to switch is maintenance, not purity:
#
#   piped-backend image built  2026-03-26, last upstream commit 2026-05-29
#   invidious-companion image built 2026-08-01  ← today
#
# The container is the piece doing the actual fighting with YouTube, and it is
# the piece that is actively maintained.
# -----------------------------------------------------------------------------
#
# Port layout (all on orthanc):
#   3000 — invidious (native; 0.0.0.0 so Caddy on rivendell can reach it)
#   8282 — invidious-companion (container; 127.0.0.1 ONLY — see below)
#   postgres via local unix socket, peer auth, never exposed
#
# Caddy vhost on rivendell (see modules/caddy.nix):
#   invidious.theshire.io → orthanc:3000
#
# Companion is bound to loopback and has NO `public_url` set, so Invidious
# proxies every companion request itself and the browser only ever talks to the
# one vhost. This is upstream's "simple setup". The alternative — exposing
# companion directly on its own hostname so video bytes skip a hop — is a second
# vhost and a second firewall hole for a latency win we have no evidence we
# need. Revisit only if playback is measurably slow.
#
# Unlike Piped, NO Cloudflare Tunnel is required: Invidious polls YouTube for
# subscription updates rather than receiving PubSubHubbub callbacks, so nothing
# inbound from the public internet is needed. Leave the existing piped-api
# tunnel in hosts/orthanc.nix alone until Piped is actually retired.
#
# Required sops secret (secrets/orthanc.yaml):
#   invidious_companion_key — 16 chars EXACTLY (upstream rejects any other
#                             length). Generate with `pwgen -s 16 1`.
#
# EXIT CRITERIA before retiring Piped (modules/piped.nix + its 4 containers,
# the piped-api Cloudflare tunnel, and the docker.io/postgres pin in
# renovate.json):
#   1. Video playback works in the browser, on more than one video, on the
#      device(s) actually used.
#   2. Subscriptions imported and the feed populating.
#   3. Still working ~a week later — companion's po_token can go stale, and the
#      known upstream failure mode is "worked for weeks, then every video
#      broke". A single good day proves nothing.
#
# Measured on first deploy 2026-08-01: 9 of 10 sampled videos returned 4 audio
# + 18-22 video adaptive formats, and a real 256KiB `ftypdash` fragment was
# pulled from googlevideo at 1.4MB/s. Compare Piped on the same day:
# audioStreams=0 on every video sampled.
#
# The one failure is an upstream Invidious bug, NOT a playback/token problem:
# jNQXAC9IVRw ("Me at the zoo", 2005) throws
#   Exception: Expected Hash for #[]?(key : String), not String
# in the Crystal metadata parser and returns HTTP 200 with an EMPTY BODY — note
# the 200, so it does not look like a failure to anything checking status codes.
# It is specific to that video's ancient metadata shape and is then cached
# (1226ms first, ~780µs after). Not a blocker; worth re-checking after a version
# bump.
#
# If promoting this past the trial, still to do: Homepage tile, a Gatus monitor,
# and a decision on backing up the new native PostgreSQL (subscriptions live
# there — a restic snapshot of a live data dir is not crash-consistent, so it
# probably wants a pg_dump pre-hook rather than a raw path in
# homelab.backup.paths).

{ config, pkgs, lib, ... }:

let
  companionPort = 8282;
in

{
  # ---------------------------------------------------------------------------
  # Invidious (native) + PostgreSQL (native)
  # ---------------------------------------------------------------------------

  services.invidious = {
    enable = true;
    port = 3000;

    # Caddy lives on rivendell, not here, so this cannot bind loopback the way
    # a single-host setup would. The firewall rule below is what limits access.
    address = "0.0.0.0";

    domain = "invidious.theshire.io";

    # nginx.enable stays FALSE — that option would pull in a whole nginx +
    # ACME stack on orthanc to duplicate what Caddy already does on rivendell.
    # It is also what would normally set https_only/external_port for us, hence
    # setting them by hand below.
    nginx.enable = false;

    # createLocally provisions services.postgresql with a matching user and
    # database and connects over the local unix socket with peer auth — no
    # password anywhere. Note the module asserts db.user == db.dbname for this
    # to work; both default to "invidious" on stateVersion >= 24.05.
    database.createLocally = true;

    settings = {
      # MANDATORY behind a reverse proxy per upstream's config.example.yml —
      # this is the port Invidious believes it is reachable on and uses to build
      # absolute URLs. Wrong value here means subscription/redirect links point
      # at :3000 and break from outside.
      external_port = 443;
      https_only = true;

      # The companion handoff. private_url is Invidious → companion, in-host.
      # No public_url on purpose — see the header comment.
      invidious_companion = [
        { private_url = "http://127.0.0.1:${toString companionPort}/companion"; }
      ];

      # Single-user instance. Registration is left ENABLED for now because an
      # account is what holds subscriptions, and one has to be created before it
      # can be locked down. Flip to false once the account exists.
      registration_enabled = true;
      login_enabled = true;

      # Nothing here is public, so don't spend cycles building a "popular" page
      # or publishing instance statistics to the public instance list.
      popular_enabled = false;
      statistics_enabled = false;

      # With popular_enabled = false the stock default_home ("Popular") lands on
      # a dead page — upstream's config.example.yml says that setting "has no
      # effect when 'popular_enabled' is set to false", and `/` does in fact
      # 302 straight to /feed/popular. Point it at the feed this instance
      # actually exists to serve and drop Popular from the nav.
      #
      # Expect `/` to KEEP redirecting to /feed/popular when logged out — that
      # is not this setting failing. src/invidious/routes/misc.cr:14-19 handles
      # default_home == "Subscriptions" by checking for a user first and
      # falling back to /feed/popular when there isn't one. Verified logged-out
      # with curl; it only takes effect once signed in.
      default_user_preferences = {
        default_home = "Subscriptions";
        feed_menu = [ "Subscriptions" "Trending" "Playlists" ];
      };
    };

    # The 16-char companion key, rendered by sops and handed over as a systemd
    # credential (see below). extraSettingsFile is merged into the config by the
    # module with jq, so this file MUST be valid JSON — not YAML, and not a bare
    # key. The same constraint applies to hmacKeyFile, which is why that one is
    # left null and auto-generated into /var/lib/invidious/hmac_key instead.
    extraSettingsFile = "/run/credentials/invidious.service/companion.json";
  };

  # LoadCredential rather than a group-readable secret: the upstream unit runs
  # with DynamicUser=true AND PrivateUsers=true, and under PrivateUsers a
  # supplementary group from the host does not map into the service's user
  # namespace — the file would read as nogroup and access would fail. systemd
  # reads credentials as root before any sandboxing and re-exposes them owned by
  # the service's own uid, which sidesteps the whole problem.
  systemd.services.invidious.serviceConfig.LoadCredential =
    [ "companion.json:${config.sops.templates."invidious-companion.json".path}" ];

  # One secret, two consumers, two formats. Templating from a single
  # sops.placeholder is what keeps them from drifting — if these two ever
  # disagree, Invidious and companion silently fail to authenticate to each
  # other and every video breaks.
  sops.secrets.invidious_companion_key = { };

  sops.templates."invidious-companion.json".content = builtins.toJSON {
    invidious_companion_key = config.sops.placeholder.invidious_companion_key;
  };

  # Consumed by podman as root, so default 0400 root:root is correct here.
  sops.templates."invidious-companion.env".content =
    "SERVER_SECRET_KEY=${config.sops.placeholder.invidious_companion_key}";

  # ---------------------------------------------------------------------------
  # invidious-companion (container — see header for why this cannot be native)
  # ---------------------------------------------------------------------------

  virtualisation.oci-containers.containers.invidious-companion = {
    image = "quay.io/invidious/invidious-companion:latest@sha256:d7fd997abf03e4d01af05144f2896f3fe56747225df78d41c0431299b52ae191";
    autoStart = true;

    # Loopback-only. Invidious proxies for it; nothing external should reach it.
    ports = [ "127.0.0.1:${toString companionPort}:${toString companionPort}" ];

    environmentFiles = [ config.sops.templates."invidious-companion.env".path ];

    # youtubei.js caches the player + the minted po_token here. Persisting it
    # across restarts avoids re-solving YouTube's challenge on every boot.
    volumes = [ "/var/lib/invidious-companion/cache:/var/tmp/youtubei.js:rw" ];

    # Upstream's recommended hardening, verbatim from the production compose.
    extraOptions = [
      "--cap-drop=ALL"
      "--security-opt=no-new-privileges"
      "--read-only"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/invidious-companion       0755 root root -"
    "d /var/lib/invidious-companion/cache 0777 root root -"
  ];

  # Only Invidious is reachable off-host, and only so Caddy can proxy it.
  networking.firewall.allowedTCPPorts = [ 3000 ];

  # NB for whoever reads `systemctl status invidious` and panics: the upstream
  # module sets RuntimeMaxSec=1h with a randomized 5min offset, so this service
  # is SUPPOSED to restart roughly hourly. Upstream requires it. A rising
  # restart count is normal here and is not a crash loop.
  homelab.postUpgradeCheck.services = [ "invidious" "podman-invidious-companion" ];
}
