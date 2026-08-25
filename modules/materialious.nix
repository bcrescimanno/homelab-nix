# modules/materialious.nix — Materialious: Material Design frontend for Invidious
#
# -----------------------------------------------------------------------------
# STATUS 2026-08-25: PROMOTED. This is the YouTube frontend actually used, at
# yt.theshire.io. Piped is decommissioned and Invidious is out of trial.
#
# Materialious is a CLIENT-SIDE app, not a server. It is a SvelteKit SPA that
# talks to the Invidious HTTP API from the browser. modules/invidious.nix is
# completely unchanged by this — same service, same companion, same database —
# and the stock Invidious UI stays reachable at invidious.theshire.io. Keep it:
# it is the same service and the same database, so it costs nothing, and it is
# the only cheap way to tell a Materialious bug apart from a companion/po_token
# or extraction failure. That distinction has already mattered twice.
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
# SAME ORIGIN — no CORS, by construction
#
# Caddy serves this app AND proxies the Invidious paths it calls under the one
# hostname (modules/caddy.nix), so the browser never makes a cross-origin
# request. VITE_DEFAULT_INVIDIOUS_INSTANCE therefore points at yt.theshire.io,
# not at the Invidious vhost.
#
# This replaced a two-origin setup that needed CORS headers on Invidious'
# vhost, and it fixed more than tidiness:
#
#   - No preflight. DASH here is <SegmentBase>, so every media fetch is a byte
#     range request, and `Range` is not CORS-safelisted — each one cost an
#     extra OPTIONS round trip. Getting that header list wrong was also a
#     silent, total playback failure while the rest of the UI worked perfectly.
#   - Nothing third-party to inspect. A page on a public-suffix domain fetching
#     from another host that resolves into RFC1918 space is, to a privacy
#     extension, indistinguishable from a site probing your LAN. First-party
#     requests get none of that treatment.
#
# The stock Invidious UI at invidious.theshire.io is untouched and still works
# as the diagnostic control described at the top. Note that the CORS block on
# the yt vhost in modules/caddy.nix is what KEEPS it working — Invidious'
# `domain` is yt.theshire.io, so the stock UI receives yt URLs for its own media
# and is itself the cross-origin consumer. It is NOT dead weight from the
# two-origin era and must not be deleted as such.
#
# CONSEQUENCE ON FIRST DEPLOY: the Invidious session cookie is per-origin, so a
# signed-in user must authorise once more under this hostname. The token itself
# is held client-side by Materialious (src/lib/auth.ts), not read from a cookie,
# so nothing else about the flow changes.
#
# -----------------------------------------------------------------------------
# UPGRADING IS FULLY MANUAL, AND NOTHING WILL REMIND YOU.
#
# renovate.json sets enabledManagers to ["nix", "custom.regex"]. The `nix`
# manager only updates flake.lock inputs, and the custom regex only matches
# `image = "repo:tag@digest"`. A `fetchFromGitHub { tag = version; }` is matched
# by neither, so this pin is invisible to Renovate and simply sits at whatever
# version it was last set to. It sat at 1.17.6 from 2026-07-29 to 2026-08-25
# while upstream shipped five releases.
#
# Renovate COULD open the version PR via a second custom manager with a
# `# renovate: datasource=github-tags` comment, but it cannot compute `hash` or
# `npmDepsHash`, so every such PR would fail CI and need the steps below by hand
# anyway. Left manual deliberately; check upstream releases when you notice
# something missing.
#
#   1. bump `version`
#   2. set `hash` to lib.fakeHash, build, take the "got:" value
#   3. nix run nixpkgs#prefetch-npm-deps -- <checkout>/materialious/package-lock.json
#      -> npmDepsHash
#   4. Re-read the build workarounds below — they are ALL
#      upstream-behaviour-dependent, and one of them (the player race condition)
#      was already made redundant by an upstream fix. --replace-fail means a
#      moved anchor breaks the build loudly, but a workaround that is no longer
#      NEEDED fails silently by simply continuing to apply.
#   5. Build for x86_64 locally before pushing. rivendell builds this on aarch64
#      and an npm build on a Pi 5 is slow; the hashes and the installCheck greps
#      are arch-independent, so a local build catches everything except the
#      compile itself.

{ pkgs, lib, ... }:

let
  # ONE definition, used both to bake the value in and to assert it landed.
  # These were two independent literals and they drifted the moment the origin
  # changed: the build then failed on its own stale assertion. The check is only
  # worth having if it cannot disagree with the thing it checks.
  instanceUrl = "https://yt.theshire.io";

  materialious = pkgs.buildNpmPackage rec {
    pname = "materialious";
    version = "1.17.11";

    src = pkgs.fetchFromGitHub {
      owner = "Materialious";
      repo = "Materialious";
      tag = version;
      hash = "sha256-8JR+A5jZRqcw4nPPBfbP9akBtlP3nViAJ1hM2KHhatk=";
    };

    sourceRoot = "${src.name}/materialious";

    npmDepsHash = "sha256-o8LuVN9CAVbErMVz4RbyDQIK91IhGEnsBTeT8MX/ERY=";

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

    # UPSTREAM BUG, FIXED UPSTREAM IN 1.17.7 — patch removed at that bump.
    #
    # Through 1.17.6 the player never mounted on a plain web build.
    # watch/[slug]/+page.svelte started two independent promises and only ONE of
    # them defined `data.video`: `getWatchPage` did, while the `playerStream`
    # handler read `data.video.premium`. `getWatchPlayer` awaits
    # `continueVideoPlayer()`, every branch of which is gated on
    # `isUnrestrictedPlatform()` — false whenever there is no own backend and no
    # Capacitor, i.e. exactly this legacy Invidious-only web build. So it
    # resolved null in a microtask while `getWatchPage` was still waiting on a
    # real /api/v1/videos round trip, the player handler ran FIRST, and it threw
    # `Cannot read properties of undefined (reading 'premium')` — aborting the
    # rest of the handler, which is where the player is actually mounted.
    #
    # The failure was silent and extremely misleading: metadata, comments,
    # thumbnails and the whole UI rendered perfectly, with no failed requests
    # and no non-2xx responses; there was simply no <video> element and no DASH
    # request ever made. It looked like a playback/CORS problem and was neither.
    #
    # Upstream shipped its own fix in 1.17.7 ("Fix race condition", 2026-08-02),
    # and it is strictly better than the one carried here: it awaits `pageStream`
    # only when `data.video` is still unset, catches a failed page load instead
    # of hanging on it, and re-guards `data.video &&` afterwards. Verified
    # present at 1.17.11 in +page.svelte. Both local substitutions are therefore
    # deleted rather than re-anchored — keeping them would now redeclare
    # `pageStream`, which upstream already declares.
    #
    # DO NOT reintroduce this patch on a future bump. If the player stops
    # mounting again, confirm against the current source first; this specific
    # ordering bug is fixed.
    postPatch = ''
      # PREFER H.264 OVER AV1 — a startup-latency fix, not a quality change.
      #
      # Invidious offers each resolution twice, as AV1 and as H.264 (no VP9).
      # Shaka picks by bandwidth efficiency, so for 1080p it takes itag 399
      # (av01.0.08M.08, 3.48 Mbit/s) over itag 137 (avc1.640028, 4.47 Mbit/s).
      # That is the right call over the internet and the wrong one here: Firefox
      # software-decodes AV1 via dav1d on virtually all hardware, while H.264
      # gets hardware decode. Measured server-side throughput through the
      # proxy is 17-27 MB/s, so saving 1 Mbit/s buys nothing and costs
      # time-to-first-frame. Note Invidious' own stock player falls back to
      # H.264 (itag 18), which is part of why it feels instant by comparison.
      #
      # Same resolution either way — 1080p stays 1080p, only the codec changes.
      #
      # DON'T START AT 360p. shaka's ABR opens with a conservative bandwidth
      # estimate and ramps up, so the first variant it decodes is 360p — a
      # Firefox profile caught `DecodeFrame ... 640x360 hw,h264,VAAPI_SURFACE`
      # followed by ~25s of nothing. Hardware decoders are at their flakiest
      # initialising at small resolutions, and on the RTX 5090 workstation each
      # attempt hit media.rdd-process.startup_timeout_ms (5000ms) and retried —
      # MediaPDecoder threads respawning at measured 5020ms intervals. It is
      # also why a SECOND load of the same video was always fast: shaka had
      # cached the bandwidth estimate by then and started straight at 1080p,
      # skipping the low-resolution init entirely.
      #
      # 50 Mbit/s is not a fudge — measured throughput through the proxy is
      # 17-27 MB/s (~136-216 Mbit/s), and the top variant is 4.47 Mbit/s. This
      # tells shaka the truth about the link so the first load behaves like the
      # second. See [[firefox-vaapi-nvidia-stall]] for the full diagnosis.
      #
      # A SECOND configure() call rather than editing the big object literal
      # above: shaka merges config, and `player.configure({` appears 5 times in
      # the tree so it is not a safe unique anchor. This anchors on a line that
      # is unique within Player.svelte.
      #
      # Verified by measuring which itags the player actually fetches:
      # before ['140','399'] (AAC + AV1), after ['137','140'] (H.264 + AAC).
      P='src/lib/components/player/Player.svelte'
      substituteInPlace "$P" \
        --replace-fail \
          'if (playerElement) playerElement.loop = $playerAlwaysLoopStore;' \
          'player.configure({ preferredVideoCodecs: ['"'"'avc1'"'"'], abr: { defaultBandwidthEstimate: 50000000 } }); if (playerElement) playerElement.loop = $playerAlwaysLoopStore;'
    '';

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
      # ITS OWN ORIGIN, not invidious.theshire.io. Caddy proxies the Invidious
      # paths under this same hostname (see modules/caddy.nix), so every request
      # the browser makes is first-party. Pointing this at the Invidious vhost
      # is what created the cross-origin problems described in the header.
      VITE_DEFAULT_INVIDIOUS_INSTANCE=${instanceUrl}

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

      grep -rqF '${instanceUrl}' $out/_app \
        || { echo "FAIL: instance URL ${instanceUrl} was not baked into the bundle"; exit 1; }

      if grep -rq 'VITE_DEFAULT_[A-Z_]*_PLACEHOLDER' $out; then
        echo "FAIL: unsubstituted upstream placeholder left in the bundle"; exit 1
      fi

      grep -rq '{"proxyVideos":true,"darkMode":true,"themeColor":"#2596be","region":"US"}' $out/_app \
        || { echo "FAIL: default settings JSON is missing or was truncated (dotenv '#' comment?)"; exit 1; }

      # The shaka config is injected by postPatch into a minified bundle;
      # --replace-fail proves the ANCHOR matched, not that the payload survived
      # the build. Assert both settings are actually present in the output.
      grep -rqF 'defaultBandwidthEstimate' $out/_app \
        || { echo "FAIL: ABR bandwidth estimate did not reach the bundle"; exit 1; }

      grep -rqF 'preferredVideoCodecs' $out/_app \
        || { echo "FAIL: codec preference did not reach the bundle"; exit 1; }

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
