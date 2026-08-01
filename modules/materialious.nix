# modules/materialious.nix — Materialious: Material Design frontend for Invidious
#
# -----------------------------------------------------------------------------
# STATUS 2026-08-01: TRIAL, alongside the stock Invidious UI.
#
# Materialious is a CLIENT-SIDE app, not a server. It is a SvelteKit SPA that
# talks to the Invidious HTTP API from the browser. modules/invidious.nix is
# completely unchanged by this — same service, same companion, same database,
# same vhost — and the stock Invidious UI stays reachable at
# invidious.theshire.io. That matters: Invidious is itself still on trial (see
# the exit criteria in invidious.nix), and if playback breaks a week from now
# the stock UI is the control that says whether it is companion's po_token or
# this frontend.
#
# -----------------------------------------------------------------------------
# WHY THIS IS NOT A CONTAINER
#
# Upstream ships `wardpearce/materialious`, but that image is only nginx serving
# an `adapter-static` build, plus a `replace_env_vars.sh` that seds the VITE_*
# placeholders into the built JS at container start. There is no server-side
# component at all in the legacy (Invidious-only) deployment — the FULL image
# (`materialious-full`) is the one with an account system, its own database and
# an SSR backend, and we want none of that for a single-user LAN instance.
#
# So the image buys nothing here. buildNpmPackage produces the same static tree
# with the real values compiled in, and Caddy — already running on this host and
# already terminating TLS for every other vhost — serves it directly. No
# container, no second nginx, no runtime string substitution, and the config is
# in the Nix expression rather than in a shell script inside an image. This is
# strictly more declarative than the stack it plugs into.
#
# -----------------------------------------------------------------------------
# INVIDIOUS COMPANION: `public_url` IS NOT REQUIRED, DESPITE THE DOCS
#
# docs/DOCKER.md says `public_url` MUST be set under `invidious_companion` for
# companion to work with Materialious. Following that would mean reversing the
# deliberate decision in modules/invidious.nix — exposing companion on its own
# hostname, with its own firewall hole and its own CORS block, purely to save
# one proxy hop.
#
# It is not required. src/lib/components/player/Player.svelte:294 —
#
#     // Due to CORs issues with redirects, hosted instances of Materialious
#     // dirctly provide the companion instance
#     // while clients can just use the reirect provided by Invidious' API
#     if (getPublicEnv('DEFAULT_COMPANION_INSTANCE')) {
#       dashUrl = `${COMPANION}/api/manifest/dash/id/${videoId}`;
#     } else {
#       dashUrl = data.video.dashUrl;   // <- Invidious' own manifest URL
#     }
#
# With VITE_DEFAULT_COMPANION_INSTANCE left EMPTY (below) it uses the dash URL
# Invidious already returns, so every request stays on the one vhost and
# companion stays bound to loopback on orthanc. Do not "fix" the empty value.
#
# The redirect problem that comment refers to is avoided by `?local=true`, which
# makes Invidious proxy the media bytes instead of 302-ing to googlevideo (a
# cross-origin redirect drops the CORS headers). On this build that is not even
# a preference — Player.svelte:304 appends it whenever
# `!isUnrestrictedPlatform()`, and misc.ts:114 defines that as "no own backend
# AND not a Capacitor native platform", which is exactly a plain web build.
# `proxyVideos: true` below is belt-and-braces for the Android/desktop apps if
# they are ever pointed at this instance.
#
# Consequence worth knowing: video bytes transit orthanc rather than going
# browser -> googlevideo directly. That is why the invidious.theshire.io vhost
# in modules/caddy.nix sets `flush_interval -1`; without it Firefox's MSE times
# out waiting on Caddy's response buffering. It was already there for the stock
# UI, and this makes it load-bearing for both.
#
# -----------------------------------------------------------------------------
# CORS
#
# The browser loads the app from yt.theshire.io and calls the API on
# invidious.theshire.io — two origins, so Invidious' vhost has to return CORS
# headers. Invidious has no setting for this, so it is done in the reverse
# proxy; see the CORS block on invidious.theshire.io in modules/caddy.nix. The
# allowed origin is pinned to this vhost, not `*`, because the responses are
# sent with credentials.
#
# -----------------------------------------------------------------------------
# UPGRADING (manual — Renovate's custom manager only matches container images)
#
#   1. bump `version`
#   2. set `hash` to lib.fakeHash, build, take the "got:" value
#   3. nix run nixpkgs#prefetch-npm-deps -- <checkout>/materialious/package-lock.json
#      -> npmDepsHash
#
# Re-read this header's three build workarounds after any bump; they are all
# upstream-behaviour-dependent.

{ pkgs, lib, ... }:

let
  materialious = pkgs.buildNpmPackage rec {
    pname = "materialious";
    version = "1.17.6";

    src = pkgs.fetchFromGitHub {
      owner = "Materialious";
      repo = "Materialious";
      tag = version;
      hash = "sha256-j8XQtBN1K0TDiK5nn7I5o/tYUybHW0gDy3Hns0a3xyE=";
    };

    sourceRoot = "${src.name}/materialious";

    npmDepsHash = "sha256-schUn0ZNAen2iGtrQ7ohA8WVT2/OJbCSbYEKpHMOHPg=";

    # WORKAROUND 1 — `sharp` (a devDependency reached via @capacitor/assets, and
    # used only to generate mobile app icons) has a postinstall that downloads a
    # libvips binary. That cannot work in the sandbox and fails the build.
    #
    # Skipping install scripts also skips the `patch:shaka` postinstall, which
    # only appends `export default shaka;` to shaka-player's .d.ts files. That
    # is a TypeScript-types-only fix and `vite build` does not typecheck
    # (`npm run check` does, and is not run here), so the web build does not
    # need it. Verified: the build completes and the output is complete.
    npmFlags = [ "--ignore-scripts" ];

    preBuild = ''
      # WORKAROUND 2 — `npm run build` runs scripts/githubContributors.mjs,
      # which fetches api.github.com for the About page's contributor list.
      # Impossible in the sandbox. The script swallows its own error rather than
      # exiting non-zero, so the build survives, but it leaves the file absent
      # and the page fetching a 404. Seed valid empty JSON instead.
      mkdir -p static/localApi
      echo '[]' > static/localApi/ghContributors.json

      # Upstream's Dockerfile writes placeholder values here and seds the real
      # ones in at container start. We have the real values at build time, so
      # they go straight in and no runtime substitution exists to go wrong.
      #
      # WORKAROUND 3 / TRAP — VITE_DEFAULT_SETTINGS MUST stay single-quoted.
      # It is JSON containing `"themeColor": "#2596be"`, and in an unquoted
      # dotenv value the `#` opens a comment: the JSON silently truncates
      # mid-string, swallows the following line, and bakes a corrupt settings
      # blob into the bundle with no error anywhere. The installCheck below
      # exists specifically to catch that regression.
      cat > .env <<'EOF'
      VITE_DEFAULT_INVIDIOUS_INSTANCE=https://invidious.theshire.io

      # Deliberately EMPTY — see the companion section in the header comment.
      # Setting this would require exposing companion publicly.
      VITE_DEFAULT_COMPANION_INSTANCE=

      # Empty disables Return YouTube Dislike entirely. Enabling it would send
      # every video ID watched here to a third party; making it private again
      # means self-hosting ryd-proxy, which is two more containers (one of them
      # a Tor daemon) for a dislike count.
      VITE_DEFAULT_RETURNYTDISLIKES_INSTANCE=

      # SponsorBlock and DeArrow are AVAILABLE but not force-enabled — upstream
      # defaults them to off, and turning them on is a per-browser preference.
      # Note that using either does send video IDs to sponsor.ajay.app.
      VITE_DEFAULT_SPONSERBLOCK_INSTANCE=https://sponsor.ajay.app
      VITE_DEFAULT_DEARROW_INSTANCE=https://sponsor.ajay.app
      VITE_DEFAULT_DEARROW_THUMBNAIL_INSTANCE=https://dearrow-thumb.ajay.app

      VITE_DEFAULT_SETTINGS='{"proxyVideos":true,"darkMode":true,"themeColor":"#2596be","region":"US"}'
      EOF
    '';

    # adapter-static emits a plain SPA into build/ — no node runtime, no server.
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r build/* $out/
      runHook postInstall
    '';

    # Everything above is silent-failure-shaped: a broken .env still produces a
    # complete-looking 11MB site that only misbehaves in the browser. Assert the
    # values actually landed.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck

      grep -rq 'invidious\.theshire\.io' $out/_app \
        || { echo "FAIL: Invidious instance URL was not baked into the bundle"; exit 1; }

      if grep -rq 'VITE_DEFAULT_[A-Z_]*_PLACEHOLDER' $out; then
        echo "FAIL: unsubstituted upstream placeholder left in the bundle"; exit 1
      fi

      grep -rq '{"proxyVideos":true,"darkMode":true,"themeColor":"#2596be","region":"US"}' $out/_app \
        || { echo "FAIL: default settings JSON is missing or was truncated (dotenv '#' comment?)"; exit 1; }

      test -f $out/index.html || { echo "FAIL: no index.html"; exit 1; }

      runHook postInstallCheck
    '';

    meta = {
      description = "Material Design frontend for YouTube and Invidious";
      homepage = "https://github.com/Materialious/Materialious";
      license = lib.licenses.agpl3Only;
      platforms = lib.platforms.all;
    };
  };
in

{
  # Exposed as pkgs.materialious so modules/caddy.nix can serve it; the vhost
  # itself lives there with every other vhost, and needs that file's shared
  # DNS-01 tls block.
  nixpkgs.overlays = [ (final: prev: { inherit materialious; }) ];
}
