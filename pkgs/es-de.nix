# pkgs/es-de.nix — ES-DE (EmulationStation Desktop Edition), terra's emulator
# frontend.
#
# Packaged here because nixpkgs removed `emulationstation-de` on 2025-10-23
# ("numerous vulnerabilities in freeimage"). Upstream's AppImage still bundles
# FreeImage — the exposure is box art fetched from ScreenScraper on a console
# with nothing else on it, which was accepted knowingly (2026-10-09).
#
# A manual pin. Neither Renovate nor scripts/refresh-pins can see it: the
# download URL is a GitLab package_files id with no version in it. ES-DE's own
# update check still runs and announces a new release on startup — that
# notification is the signal to bump. Its in-app updater cannot work (it
# replaces the AppImage, which lives in the read-only store); ignore it.
#
# To bump: the release's ES-DE_x64.AppImage link is in
#   curl -s 'https://gitlab.com/api/v4/projects/es-de%2Femulationstation-de/releases?per_page=1' \
#     | jq -r '.[0] | .tag_name, (.assets.links[] | select(.name == "ES-DE_x64.AppImage") | .url)'
# then `nix store prefetch-file --hash-type sha256 <url>` for the hash.
#
# No find-rules override is needed for RetroArch: ES-DE's bundled
# es_find_rules.xml already lists /run/current-system/sw/lib/retroarch/cores,
# which hosts/terra.nix provides by putting the cores in systemPackages.

{ appimageTools, fetchurl }:

let
  pname = "es-de";
  version = "3.5.0";

  src = fetchurl {
    url = "https://gitlab.com/es-de/emulationstation-de/-/package_files/357718352/download";
    name = "ES-DE_x64-${version}.AppImage";
    hash = "sha256-q8KZmhI4X4V3W9P5hvqJHHa2nfN5H3wS5MeDzzw2MPU=";
  };

  contents = appimageTools.extract { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;

  extraInstallCommands = ''
    install -Dm444 ${contents}/org.es_de.frontend.desktop -t $out/share/applications
    install -Dm444 ${contents}/org.es_de.frontend.svg -t $out/share/icons/hicolor/scalable/apps
  '';

  meta.mainProgram = "es-de";
}
