# pkgs/konveyor.nix — Konveyor, scrolling column tiling for KWin (celes).
# https://github.com/DevL0rd/Konveyor
#
# A compiled KWin effect, so it must be built against the exact KWin it loads
# into. Upstream's install.sh solves that by rebuilding from a git checkout on
# every system update; here the Nix dependency on kdePackages.kwin does it.
#
# What install.sh does that this replaces:
#   - builds against the running KWin  → the kdePackages.kwin input; a KWin
#     bump rebuilds this package, so the ABI can never drift
#   - copies the .so under a timestamped plugin id and writes
#     `<id>Enabled=true` into kwinrc → the timestamp only exists so a live
#     KWin can load a fresh copy without a logout. Here the effect keeps its
#     own id, `konveyor_effect`, and metadata.json's EnabledByDefault is
#     flipped to true, so being installed is what turns it on. An explicit
#     `konveyor_effectEnabled=false` in kwinrc (the Desktop Effects checkbox)
#     still overrides it.
#   - disables karousel/krohnkite/kzones/polonium/bismuth → none installed.
#   - shortcut and window-rule takeover is NOT the installer's: the effect does
#     it itself at runtime (src/shortcuts/shortcutconflicts.cpp) and hands them
#     back when unloaded.
#
# Not built: the widgets (widgets/, git submodule Plasma-Shared) and their
# launcher swap. process_monitor_telemetry.so is built by CMake regardless but
# stays EnabledByDefault=false; it only feeds the Process Monitor widget.
#
# Settings live in ~/.config/konveyor/config.kdl, written by the KCM (System
# Settings → Window Management → Konveyor, or Meta+K → Settings) — user state,
# not Nix.
#
# A manual pin, invisible to Renovate and scripts/refresh-pins: upstream has
# no releases and pushes most days, and a pinned commit means a bad one never
# lands by itself. To bump:
#     gh api repos/DevL0rd/Konveyor/commits/main --jq '.sha, .commit.committer.date'
#     nix-prefetch-url --unpack https://github.com/DevL0rd/Konveyor/archive/<sha>.tar.gz
#   then set rev, sha256 and the version date.
{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  kdePackages,
  libxkbcommon,
  libepoxy,
  libdrm,
  pipewire,
  vulkan-headers,
  vulkan-loader,
  wayland,
  xorg,
}:

stdenv.mkDerivation {
  pname = "konveyor";
  version = "0.1.0-unstable-2026-11-17";

  src = fetchFromGitHub {
    owner = "DevL0rd";
    repo = "Konveyor";
    rev = "178b9f2291401a1bdf644ca1019d0940ae777231";
    sha256 = "0il8q3wxhny8jdi0dm60793asfzz97cvwpia272pzbrff2a48sx6";
  };

  postPatch = ''
    substituteInPlace src/effect/plugin/metadata.json \
      --replace-fail '"EnabledByDefault": false' '"EnabledByDefault": true'
  '';

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    kdePackages.extra-cmake-modules
    kdePackages.wrapQtAppsHook
    kdePackages.qtshadertools
  ];

  buildInputs = with kdePackages; [
    qtbase
    qtdeclarative
    qtshadertools
    kwin
    kdecoration
    kglobalaccel
    kconfig
    kcolorscheme
    knotifications
    kcoreaddons
    ki18n
    kwindowsystem
    kcmutils
    kservice
    libplasma
    kirigami
    kirigami-addons
    layer-shell-qt
    libkscreen
    libxkbcommon
    libepoxy
    libdrm
    pipewire
    vulkan-headers
    vulkan-loader
    wayland
    xorg.libxcb
    xorg.xcbutilwm
  ];

  cmakeFlags = [
    (lib.cmakeBool "KONVEYOR_BUILD_TESTS" false)
    (lib.cmakeBool "CMAKE_COMPILE_WARNING_AS_ERROR" false)
  ];

  meta = {
    description = "Scrolling column tiling for KDE Plasma";
    homepage = "https://github.com/DevL0rd/Konveyor";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };
}
