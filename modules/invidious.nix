# modules/invidious.nix — Invidious: privacy-respecting YouTube frontend
#
# -----------------------------------------------------------------------------
# STATUS 2026-08-25: PROMOTED. This is the YouTube frontend. Piped is retired.
#
# Piped ran side by side with this from 2026-08-01 until its decommission on
# 2026-08-25: modules/piped.nix, its four containers (postgres/backend/frontend/
# proxy), the piped* Caddy vhosts, the Homepage tile, and the piped-api ingress
# on orthanc's Cloudflare Tunnel are all gone. Piped's playback was dead —
# YouTube's PoToken/SABR enforcement defeating a NewPipeExtractor that upstream
# had stopped maintaining (last Piped-Backend commit 2026-05-29, image built
# 2026-03-26, /streams/<id> returning audioStreams=0 on every video sampled).
# The exit criteria that gated this retirement are recorded at the bottom of
# this comment; all three were met.
#
# WHAT SURVIVES PIPED, and must not be "cleaned up" as leftovers:
#   - orthanc's Cloudflare Tunnel, still ATTRIBUTE-NAMED "piped-api" in
#     hosts/orthanc.nix. It now carries only stream.theshire.io (Navidrome) and
#     the name is load-bearing in cloudflared.yml. See the comment there.
#   - The stock Invidious UI at invidious.theshire.io. Materialious on
#     yt.theshire.io is the UI actually used; the stock UI is the same service
#     and the same database, and is the control that distinguishes a frontend
#     bug from a companion/extraction failure. It costs nothing. Keep it.
#
# The DAY ONE user-facing frontend is Materialious (modules/materialious.nix),
# not the stock UI — read that module's header before touching this one's
# `domain`, which points at yt.theshire.io on purpose.
#
# -----------------------------------------------------------------------------
# THIS IS NOT A FULLY-NATIVE REPLACEMENT.
#
# The "replace 4 containers with a native service" framing that originally
# justified this migration was wrong on the one point that decides the whole
# thing. Invidious ALSO cannot
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
# NO Cloudflare Tunnel is required by this module: Invidious POLLS YouTube for
# subscription updates rather than receiving PubSubHubbub callbacks, so nothing
# inbound from the public internet is needed. This is why retiring Piped let the
# tunnel's piped-api ingress go — the tunnel itself stayed, for Navidrome.
#
# Required sops secret (secrets/orthanc.yaml):
#   invidious_companion_key — 16 chars EXACTLY (upstream rejects any other
#                             length). Generate with `pwgen -s 16 1`.
#
# EXIT CRITERIA that gated retiring Piped — ALL MET, retired 2026-08-25.
# Kept because they are the same criteria to re-apply if playback here ever
# degrades and a replacement is evaluated:
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
# PROMOTION CHECKLIST: Homepage tile DONE (modules/homepage.nix, pointing at
# yt.theshire.io). Gatus monitors DONE — "Invidious" plus "Invidious playback",
# the latter asserting adaptiveFormats length AND the presence of an audio/*
# entry, because zero audio streams is exactly how Piped died and a status-only
# check calls that healthy.
#
# Backups: CLOSED 2026-09-20. Nothing backed up the native PostgreSQL for the
# first two months of this module's life, and SUBSCRIPTIONS LIVE THERE — 53 of
# them, in one row of `users`, with no second copy anywhere. Piped's database
# was never backed up either, so it was an inherited gap rather than a
# regression, but it was the only genuine data-loss exposure left in the lab.
# `backup-invidious` below dumps the database to backupDir at 02:30 and restic's
# 03:00 local run picks that directory up. The live data dir is deliberately NOT
# in homelab.backup.paths: a restic snapshot of running PostgreSQL is not
# crash-consistent, so it would restore to a torn WAL rather than a database.
# Same shape as backup-vaultwarden in modules/vaultwarden.nix.

{ config, pkgs, lib, ... }:

let
  companionPort = 8282;

  ntfyUrl = "http://10.0.1.9:2586/homelab";
  host    = config.networking.hostName;

  # Local disk. A SIBLING of /var/backup/erebor, never inside it — that path is
  # the NFS mount in modules/backup.nix, and dumping the database onto the
  # backup share would make the snapshot depend on erebor being up.
  backupDir = "/var/backup/invidious";
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

    # yt.theshire.io — the MATERIALIOUS vhost, deliberately, even though the
    # stock UI lives at invidious.theshire.io.
    #
    # This setting is what Invidious uses to build every absolute URL it hands
    # out: `dashUrl`, `videoThumbnails[].url`, `adaptiveFormats[].url`. Those
    # are absolute regardless of which hostname served the response, so with it
    # pointed at invidious.theshire.io the API told Materialious to fetch all
    # media from the OTHER origin — which silently defeated the same-origin
    # split in modules/caddy.nix (46 of ~62 cross-origin requests were the media
    # itself). Serving the API from a second hostname is not enough; the URLs
    # inside the payload have to agree.
    #
    # Consequence: the stock UI at invidious.theshire.io now receives
    # yt.theshire.io URLs and is itself the cross-origin consumer, which is why
    # the CORS block moved to the yt vhost. See modules/caddy.nix.
    domain = "yt.theshire.io";

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

      # CLOSED 2026-08-01, immediately after the account was created. This is
      # ordinary hygiene for a single-user instance — the one account that holds
      # the subscriptions exists, so nothing else needs to be creatable.
      #
      # RETRACTION: the commit that first set this (and the comment it landed
      # with) claimed invidious.theshire.io was reachable from the public
      # internet and that 443 was forwarded to Caddy. THAT WAS WRONG. Nothing
      # here is internet-facing. Corrected 2026-08-01 with two independent
      # checks: a phone off wifi timed out on dl.theshire.io, and a tcpdump on
      # rivendell's eth0 saw 36 SYNs to :443 during the test window from
      # 10.0.1.247 and 10.0.1.9 only — zero non-RFC1918 sources.
      #
      # The bad claim came from a bad instrument: WebFetch runs LOCALLY, on the
      # LAN, so it resolved the hostname through the split-horizon zone in
      # modules/dns.nix (*.theshire.io -> 10.0.1.9) and reached Caddy directly.
      # It returned a real page, which looked exactly like proof of exposure.
      # **WebFetch cannot test external reachability of anything on this
      # network.** Public DNS *does* point *.theshire.io at the WAN IP, which is
      # what made the story plausible — but a DNS record is not an open port.
      # To actually test from outside, use a device on cellular, or a host that
      # is genuinely off-network.
      #
      # login_enabled stays true: the account is needed to read subscriptions,
      # both in a browser and from a native client over the API.
      registration_enabled = false;
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
    image = "quay.io/invidious/invidious-companion:latest@sha256:f15bc688aedd4bbb76cc636c7cc0cfff9b2b9f0734a4b831efbda7253b180525";
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

    # 0700 postgres: the dump is written by backup-invidious running AS
    # postgres. restic runs as root, so it reads this regardless.
    "d ${backupDir} 0700 postgres postgres -"
  ];

  # Only Invidious is reachable off-host, and only so Caddy can proxy it.
  networking.firewall.allowedTCPPorts = [ 3000 ];

  # NB for whoever reads `systemctl status invidious` and panics: the upstream
  # module sets RuntimeMaxSec=1h with a randomized 5min offset, so this service
  # is SUPPOSED to restart roughly hourly. Upstream requires it. A rising
  # restart count is normal here and is not a crash loop.
  # ---------------------------------------------------------------------------
  # Database snapshot for restic
  #
  # restic must never be pointed at PostgreSQL's live data directory: it walks
  # the tree file by file while the server is writing to it, so the result is a
  # torn copy that looks like a successful backup and restores as a corrupt
  # cluster. A logical dump is the only consistent thing to archive, and
  # pg_dump takes its own MVCC snapshot, so this needs no downtime.
  #
  # The dump is written to a temp file and renamed into place. Without that,
  # restic's 03:00 run could catch a half-written dump and archive it — the
  # failure would be invisible until a restore was attempted, which is the
  # specific way #569 stayed green for four months.
  #
  # Roles are deliberately NOT dumped (no pg_dumpall --globals-only): the
  # `invidious` role and database are recreated declaratively by
  # database.createLocally on any fresh deploy, so a globals dump would restore
  # state that Nix already owns.
  #
  # Restore:
  #   systemctl stop invidious
  #   sudo -u postgres dropdb invidious
  #   sudo -u postgres createdb -O invidious invidious
  #   gzip -dc /var/backup/invidious/invidious.sql.gz | sudo -u postgres psql invidious
  #   systemctl start invidious
  # ---------------------------------------------------------------------------

  systemd.services.backup-invidious = {
    description = "Dump the Invidious database for restic";
    requires = [ "postgresql.service" ];
    after    = [ "postgresql.service" ];

    # Both markers, for the reason spelled out at length in modules/music-sync.nix:
    # switch-to-configuration starts timer-driven oneshots mid-activation, and a
    # dump attempted while postgresql is still restarting fails the unit, fails
    # s-t-c, and pushes a false "Upgrade FAILED". restartIfChanged only covers
    # ACTIVE units; a timer oneshot is inactive, so X-OnlyManualStart is the one
    # that actually makes s-t-c skip it. The timer is the only legitimate trigger.
    restartIfChanged = false;
    unitConfig = {
      X-OnlyManualStart = true;
      OnFailure = "backup-invidious-notify-failure.service";
    };

    serviceConfig = {
      Type  = "oneshot";
      # Peer auth over the unix socket — no password anywhere, matching
      # database.createLocally. postgres is superuser, so it can dump any db.
      User  = "postgres";
      Group = "postgres";
      UMask = "0077";
    };

    script = ''
      set -euo pipefail

      tmp="${backupDir}/invidious.sql.gz.tmp"
      dst="${backupDir}/invidious.sql.gz"

      # pipefail is what makes a pg_dump failure fail the unit — without it the
      # exit status would be gzip's, which reports success on a truncated
      # stream and would publish an empty dump over a good one.
      ${config.services.postgresql.package}/bin/pg_dump \
        --no-owner --no-privileges invidious \
        | ${pkgs.gzip}/bin/gzip -9 > "$tmp"

      ${pkgs.coreutils}/bin/mv -f "$tmp" "$dst"
    '';
  };

  systemd.timers.backup-invidious = {
    description = "Nightly Invidious database snapshot";
    wantedBy = [ "timers.target" ];
    # Ahead of restic's local run (03:00 plus up to 1h jitter, see
    # modules/backup.nix), so the archived dump is at most ~1.5h old.
    # Persistent so a host that was down at 02:30 dumps on the next boot
    # rather than silently skipping a day.
    timerConfig = {
      OnCalendar = "02:30";
      Persistent = true;
    };
  };

  # A failing dump would otherwise be silent: restic would keep archiving the
  # last good file forever, and the restic freshness check in modules/backup.nix
  # only proves restic itself ran.
  systemd.services.backup-invidious-notify-failure = {
    description = "Notify ntfy that the Invidious database snapshot failed";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = ''
        ${pkgs.curl}/bin/curl -s --connect-timeout 5 --max-time 30 \
          --retry 3 --retry-delay 10 --retry-all-errors \
          -H 'Title: Invidious snapshot FAILED' \
          -H 'Priority: 4' \
          -H 'Tags: warning' \
          -d '${host}: backup-invidious failed, restic is archiving a stale database — check journalctl -u backup-invidious' \
          ${ntfyUrl}
      '';
    };
  };

  homelab.backup.paths = [ backupDir ];

  homelab.postUpgradeCheck.services = [ "invidious" "podman-invidious-companion" ];
}
