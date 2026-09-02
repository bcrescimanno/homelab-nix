# pkgs/materialious.nix — Material Design frontend for YouTube and Invidious
#
# The SPA served at yt.theshire.io. Why it is built here rather than pulled as a
# container, and how it is served, is documented in modules/materialious.nix —
# this file is only the build.
#
# -----------------------------------------------------------------------------
# UPGRADING IS AUTOMATED NOW. READ THIS ANYWAY BEFORE MERGING ONE.
#
# This pin used to be invisible to every piece of tooling in the repo:
# renovate.json's enabledManagers covers flake inputs and container images, and
# a `fetchFromGitHub { tag = version; }` is matched by neither. It sat at 1.17.6
# from 2026-07-29 to 2026-08-25 while upstream shipped five releases, and the
# only reason it ever moved was somebody noticing.
#
# It is now exposed as a flake output (`.#materialious`), which lets nix-update
# compute `version`, `src.hash` and `npmDepsHash` on its own — the exact
# objection that made this manual. scripts/refresh-pins does that, and
# .github/workflows/refresh-pins.yml runs it weekly and opens a PR. That PR goes
# through the same required native builds as everything else, so a bump that
# does not compile cannot merge.
#
# WHAT THE ROBOT CANNOT DO, and why a human still reads the diff:
#
# Every workaround below is upstream-behaviour-dependent. `--replace-fail` means
# a MOVED anchor breaks the build loudly — that is the safe direction and CI
# catches it. The dangerous direction is a workaround that is no longer NEEDED:
# it keeps applying, silently, forever. One of them (a player race condition)
# was already made redundant by an upstream fix in 1.17.7 and had to be noticed
# by hand. So on every bump, re-read them against the release notes.
#
# The installCheckPhase is the backstop that makes an automated bump survivable:
# it asserts the instance URL, the default settings JSON, and BOTH shaka patches
# actually reached the built bundle. A bump that silently drops the codec fix
# fails the build rather than quietly regressing playback.
#
# -----------------------------------------------------------------------------
# WATCH LIST: getting off this derivation entirely (checked 2026-08-25)
#
# NIXPKGS — the outcome worth waiting for. Not packaged today. Two attempts,
# both closed unmerged: nixpkgs issue #328282 (package request, closed
# 2025-08-30) and PR #362445 ("materialious-desktop: init at 1.6.23", closed
# 2025-09-20). #362445 was the ELECTRON DESKTOP app and would not have helped
# regardless — this builds the web SPA's static tree. If a `materialious` web
# build lands in nixpkgs, updates arrive through ordinary flake.lock maintenance
# and this whole file can go away.
#
# CONTAINER — available already, and deliberately NOT used. This is a decision,
# not a pending item. `wardpearce/materialious` exists and renovate.json's
# custom.regex manager would digest-pin and automerge it like every other image.
# Auto-updating was never the reason to switch, and is no longer a reason at
# all now that this file updates itself. It still costs too much:
#
#   1. It cannot carry the two shaka patches below. Neither
#      `preferredVideoCodecs` nor `defaultBandwidthEstimate` is exposed upstream
#      in any configurable form — verified against 1.17.11: no VITE_ variable,
#      no settings entry, no UI toggle, and zero hits for either identifier
#      anywhere under src/. They exist ONLY because the source is patched before
#      building. A prebuilt image gives up the measured AV1 -> H.264 startup fix.
#   2. It moves config back to a runtime `replace_env_vars.sh` sed of VITE_
#      placeholders, undoing the build-time baking below and re-opening the
#      `#`-in-unquoted-dotenv truncation trap that installCheckPhase guards.
#
# So: revisit the container ONLY if upstream exposes codec/ABR preferences as
# configuration. That single change flips the trade-off.

{
  lib,
  buildNpmPackage,
  fetchFromGitHub,

  # ONE definition, used both to bake the value in and to assert it landed.
  # These were two independent literals and they drifted the moment the origin
  # changed: the build then failed on its own stale assertion. The check is only
  # worth having if it cannot disagree with the thing it checks.
  instanceUrl ? "https://yt.theshire.io",
}:

buildNpmPackage rec {
  pname = "materialious";
  version = "1.17.12";

  src = fetchFromGitHub {
    owner = "Materialious";
    repo = "Materialious";
    tag = version;
    hash = "sha256-dBOQiWxNjSE1KPGt1j33hvI1VSKTK5qkeg6+/bfQe8k=";
  };

  sourceRoot = "${src.name}/materialious";

  npmDepsHash = "sha256-v4kwkZj4PvpuFhTgDGfpI0WX2gfeO+h0mdBloXw2qbs=";

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
}
