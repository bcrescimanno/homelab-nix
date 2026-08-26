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
# The BUILD — the version pin, the shaka patches, the installCheck assertions,
# and the watch list for retiring this derivation — is pkgs/materialious.nix.
# It used to live here, invisible to Renovate; it is now a flake output that
# nix-update maintains. Everything above is about how the app is SERVED and
# stays true regardless of version.

{ pkgs, ... }:

{
  # The build lives in pkgs/materialious.nix — extracted so it can be exposed as
  # a flake output (.#materialious) and updated by nix-update, which is what
  # took this off the manual pin. Read that file's header before bumping it.
  #
  # Exposed as pkgs.materialious so modules/caddy.nix can serve it; the vhost
  # itself lives there with every other vhost, and needs that file's shared
  # DNS-01 tls block.
  nixpkgs.overlays = [
    (final: prev: { materialious = final.callPackage ../pkgs/materialious.nix { }; })
  ];
}
