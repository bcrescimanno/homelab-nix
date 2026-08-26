# pkgs/caddy-cloudflare.nix — Caddy with the Cloudflare DNS-01 plugin
#
# Split out of modules/caddy.nix so the hash below can be recomputed by tooling
# instead of by a human reading a failed CI log.
#
# -----------------------------------------------------------------------------
# THE HASH TRACKS THE GO MODULE GRAPH, NOT THE CADDY VERSION.
#
# This is the whole reason it was a recurring chore. A nixpkgs Go toolchain bump
# moves it even when neither Caddy nor the plugin changed — 2.11.4 + go 1.26.5
# did exactly that on 2026-07-31. So it goes stale on flake.lock updates, which
# is precisely when nobody is looking at this file.
#
# It was also the stated reason flake.lock updates were held back from automerge
# for months. That reasoning was already obsolete before it was removed:
# pre-build compiles this as part of rivendell's toplevel and fails loudly on a
# mismatch, and since #609 that build is a REQUIRED check. The gate always
# caught it; it just was not allowed to block, and nothing recomputed the value.
#
# `hash` is an argument rather than a literal so scripts/refresh-pins can
# override it with lib.fakeHash and read the correct value out of the resulting
# build failure, without editing this file mid-build. That runs weekly via
# .github/workflows/refresh-pins.yml and opens a PR.
#
# The FOD is architecture-independent — it is vendored Go source, not compiled
# output — so refreshing it on x86_64 is valid for the aarch64 hosts that
# actually run Caddy. That is what makes the local check in the old workflow
# ("verify the .src FOD on x86_64 before pushing") sound, and it is why the
# refresh job does not need the Pi.

{
  caddy,
  hash ? "sha256-0000000000000000000000000000000000000000000=",
}:

caddy.withPlugins {
  plugins = [ "github.com/caddy-dns/cloudflare@v0.2.3" ];
  inherit hash;
}
