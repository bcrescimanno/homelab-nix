# modules/emulation.nix — terra's emulation stack: ES-DE, RetroArch cores and
# the standalone emulators, plus where their saves are backed up.
#
# ES-DE is a launcher only: per system it runs a command like
# `%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/snes9x_libretro.so %ROM%`, and
# resolves CORE_RETROARCH and each %EMULATOR_X% from its bundled find rules
# (resources/systems/linux/es_find_rules.xml), which search PATH and
# /run/current-system/sw/lib/retroarch/cores. Everything below is installed
# system-wide, so finding emulators needs no custom_systems override.
#
# Launched from Gaming Mode as a non-Steam shortcut (Desktop Mode → Steam →
# Add a Non-Steam Game → ES-DE). That shortcut lives in Steam's data, not
# here, so a reinstall has to add it again.
#
# NOT in Nix, restored from erebor's backups share (terra/) 2026-10-09:
# ~/ROMs and ~/ES-DE (settings, gamelists, 19 GB of scraped media, themes,
# BIOS). Saves are backed up from here on — see "Backups" at the bottom.
#
# ---------------------------------------------------------------------------
# Systems and their emulators
# ---------------------------------------------------------------------------
#
# A system runs on ES-DE's default emulator — the FIRST <command> for it in
# resources/systems/linux/es_systems.xml — unless esdeDefaultEmulators below
# moves another one first. esdeSystems lists every system meant to have games,
# and esdeCheck fails the build if any of them would launch an emulator or
# core that is not installed. That is a real failure mode, not a hypothetical:
# ES-DE's PS2 default is a "PCEE2" core nixpkgs does not package, so PS2 would
# have failed at launch with nothing in Nix to say why.
#
# Arcade is FinalBurn Neo only, for now (Neo Geo and CPS1/2/3 included). MAME
# is deliberately absent: its ROM sets must match the emulator version
# exactly, and libretro.mame moves with every lock bump — phase 4.
#
# The 5th-gen-and-older consoles and handhelds run as RetroArch cores; PS2,
# GameCube/Wii, Wii U, 3DS and the original Xbox run standalone, because
# their libretro builds are either missing (PS2, Azahar), years behind
# upstream (Dolphin) or nonexistent (Cemu in nixpkgs, xemu).
#
# libretro.fbneo and libretro.picodrive are non-commercial licences, so Hydra
# never builds them and cache.nixos.org has neither. terra compiles them on a
# lock bump that changes them (minutes, not the NVIDIA module's half hour) and
# attic-push caches the result.
#
# ---------------------------------------------------------------------------
# BIOS and keys — one folder, ~/ES-DE/bios (user data, backed up)
# ---------------------------------------------------------------------------
#
# Cores ask RetroArch, never ES-DE, where BIOS files are, and RetroArch's
# system_directory points here. The standalone emulators are pointed at the
# same folder. None of these files are in Nix; what goes where:
#
#   PS1          scph5500.bin, scph5501.bin, scph5502.bin  (top level — Beetle
#                and SwanStation do not search subfolders)
#   PS2          any PS2 BIOS dump, any name, top level. PCSX2 scans the
#                folder for a 4–8 MB image that passes its BIOS check, so it
#                needs no filename configured.
#   Sega CD      bios_CD_U.bin, bios_CD_E.bin, bios_CD_J.bin
#   PCE-CD/TG-CD syscard3.pce
#   Saturn       sega_101.bin (JP), mpr-17933.bin (US/EU)
#   Dreamcast    dc/dc_boot.bin, dc/dc_flash.bin (optional — Flycast falls
#                back to its HLE BIOS)
#   Neo Geo      neogeo.zip, next to the games in ~/ROMs/neogeo (FinalBurn Neo
#                looks there first)
#   Neo Geo CD   neocd/ (neocd_z.rom or one of the other BIOS sets NeoCD lists)
#   GBA          gba_bios.bin (optional)
#   Wii U        wiiu/keys.txt — Cemu reads it through a symlink at
#                ~/.local/share/Cemu/keys.txt (below); games as .wua
#   Xbox         xbox/mcpx_1.0.bin and xbox/Complex_4627.bin (names fixed by
#                xemuSettings below). The HDD image is NOT a BIOS: it holds the
#                saves, lives at ~/.local/share/xemu/xemu/xbox_hdd.qcow2, and
#                starts as xemu's ready-made image from xemu.app.
#   PSP          nothing to supply: bios/PPSSPP is the core's asset folder,
#                linked from nixpkgs' ppsspp (below)
#
# ---------------------------------------------------------------------------
# Picture quality — declared, like the PS1/N64 upscaling before it
# ---------------------------------------------------------------------------
#
# RetroArch: `settings` are passed as --appendconfig on EVERY launch, so they
# override RetroArch's own retroarch.cfg and a change made in RetroArch's menu
# to one of these keys does not stick. Picture quality is declared; binds and
# shaders belong to the menu.
#
# Core options come from retroarchCoreOptions, one store file for every core:
# global_core_options makes RetroArch read core_options_path instead of
# ~/.config/retroarch/config/<core>/<core>.opt (those files are ignored while
# it is on). RetroArch writes the file back only when an option changed, and a
# failed write is just logged, so a Quick Menu change lasts the session and
# reverts on the next launch — same contract as `settings`. A per-GAME
# override (Quick Menu → Core Options → Manage → Save Game Options) still
# lands in the writable config dir and beats the global file.
# retroarchCoreOptionsCheck fails the build if a core drops a declared key.
# Values must match the core's own strings exactly ("memory only",
# "1x(native)") — an unknown value is ignored too, and the check cannot see
# values, only keys.
#
# - Beetle PSX HW: 8x internal resolution (2560x1920 — about 4K's height);
#   PGXP "memory only" with perspective-correct textures, which removes the
#   PS1's polygon wobble and texture warping ("memory + CPU" is labelled
#   Buggy by the core); dithering off, since upscaled dither is a visible
#   mesh, and 32bpp so that does not band. PS1 runs on it rather than ES-DE's
#   default Beetle PSX, a software renderer that cannot upscale.
#
# - Mupen64Plus-Next: ParaLLEl-RDP (accurate, Vulkan) with the ParaLLEl RSP,
#   which it requires (LLE), at 4x — 8x is the next step if every game holds
#   full speed. GLideN64 is the alternative for widescreen hacks and HD
#   texture packs but needs video_driver = gl, so it is a per-game question.
#
# - Flycast (Dreamcast): 2880x2160, 4.5x the native 640x480 and 4K's height.
#   Widescreen hack left off — it breaks culling in a lot of games.
#
# - PPSSPP (PSP): 2880x1632, 6x the native 480x272.
#
# - melonDS DS (DS): layout slot 1 is "hybrid-top" — the top screen large with
#   the touch screen beside it, because two stacked 256x192 screens are a
#   postage stamp on a 16:9 TV. Slot 2 stays the core's default, and the
#   core's "next layout" hotkey cycles between them.
#
# - video_driver = vulkan: Beetle's "hardware" renderer follows the video
#   driver, and ParaLLEl-RDP runs only on Vulkan. Every other core here is
#   driver-agnostic.
#
# The frame rate is not raised: these games run their logic at 20–30 fps,
# and the levers that exist (emulated CPU overclock, 60 fps cheats) break
# some games, so they are per-game choices, not defaults here.
#
# Standalone emulators: each keeps its own INI/XML/TOML and rewrites it from
# its UI, so a read-only home-manager file would break them. Instead each is
# wrapped so that emulation-config-merge.py runs immediately before it starts
# and writes only the keys declared below, leaving the rest of the file to
# the emulator. Two kinds of key:
#
#   set   rewritten on every launch — the same contract as RetroArch's
#         `settings`: renderer, internal resolution, fullscreen, BIOS paths,
#         and the first-run prompts that a controller cannot answer
#   seed  written only where the key is absent — a starting point the UI can
#         change for good (PCSX2's controller map, its hotkeys)
#
# Every key and value here was checked against the shipped binary at the
# 2026-10-10 lock (strings, and for xemu/Cemu/PCSX2 a round trip: seed the
# file, start the emulator headless, confirm it kept the keys).
#
# - PCSX2: Vulkan (Renderer = 14, GSRendererType::VK) at 4x (~1440p),
#   widescreen and no-interlacing patches on (applied only to games that have
#   one). SettingsVersion is seeded, never set: PCSX2 resets the whole file to
#   defaults when it is absent, and forcing today's value would loop that
#   reset on every launch once upstream bumps it. SetupWizardIncomplete=false
#   skips the first-run wizard, which needs a mouse.
#
# - Dolphin: Vulkan at 4x (2560x2112 for a 640x528 GameCube frame). The
#   analytics opt-in prompt is pre-answered (no) — it is a mouse-only dialog.
#
# - Cemu: Vulkan. Seeding settings.xml is also what skips the "Getting
#   started" wizard, which Cemu shows only when the file does not exist.
#   Upscaling on the Wii U is per-game graphic packs, so it is not set here.
#
# - Azahar: Vulkan (graphics_api 2) at 4x (1600x960 top screen), "Large
#   screen" layout (seeded — layout_option 2), mouse cursor hidden.
#
# - xemu: Vulkan at 3x (480p → 1440p), welcome screen off, BIOS paths fixed.
#   Controllers bind themselves (input.auto_bind, on by default).
#
# ---------------------------------------------------------------------------
# Controllers
# ---------------------------------------------------------------------------
#
# In Gaming Mode every game sees Steam Input's virtual pad (28de:11ff, "Steam
# Virtual Gamepad"), never the controller itself. RetroArch's default udev
# driver has no autoconfig profile for it, so the pad was detected but bound
# to nothing — games ran with no input while ES-DE (SDL) worked. The sdl2
# profile set does carry one.
#
# Gamepad combos: terra has no keyboard, and RetroArch ships with no
# controller binding for its menu or for quit — without these the only way
# out of a game is Steam's Exit Game, which kills ES-DE with it. Values are
# RetroArch's input_combo_type enum (input/input_defines.h): 2 = L3+R3,
# 4 = Start+Select. Quit returns to ES-DE; quit_press_twice (default on)
# makes it ask for a second press. PCSX2 is seeded with the same two combos
# (L3+R3 pause menu, Select+Start quit).
#
# STILL A ONE-TIME UI STEP (Desktop Mode, the Steam controller as a mouse):
# Dolphin, Cemu and Azahar key their controller profiles by device name or
# SDL GUID, which is not something to guess in Nix. Map the controller once
# in each, and in Dolphin bind a "Stop" hotkey (Select+Start) — otherwise
# leaving a game is Steam's Exit Game. Wii games additionally need the Wii
# Remote emulated (pointer on the right stick or Steam Input gyro, shake and
# tilt on spare buttons), often per game. Those profiles are backed up.

{ config, pkgs, lib, ... }:

let
  home = "/home/brian";
  bios = "${home}/ES-DE/bios";

  es-de = pkgs.callPackage ../pkgs/es-de.nix { };

  # Saves, configs and BIOS — see "Backups" at the bottom.
  backupPaths = map (p: "${home}/${p}") [
    ".config/retroarch" # retroarch.cfg, saves/ (incl. PSP), states/
    "ES-DE/gamelists" # play counts, favourites, per-game emulator choices
    "ES-DE/collections"
    "ES-DE/settings"
    "ES-DE/bios"
    ".config/PCSX2" # memcards/, sstates/, inis/
    ".config/dolphin-emu"
    ".local/share/dolphin-emu" # GC/ memory cards, Wii/ NAND saves, StateSaves/
    ".config/Cemu" # settings.xml, controllerProfiles/
    ".local/share/Cemu/mlc01/usr/save" # not the rest of mlc01: updates and DLC
    ".config/azahar-emu"
    ".local/share/azahar-emu" # sdmc/ and nand/ saves, states/
    ".local/share/xemu/xemu" # xemu.toml, eeprom, xbox_hdd.qcow2 (the saves)
  ];

  # ---- RetroArch -----------------------------------------------------------

  retroarch = pkgs.retroarch-bare.wrapper {
    cores = with pkgs.libretro; [
      # Nintendo
      mesen # NES
      snes9x # SNES
      mupen64plus # N64
      gambatte # Game Boy, Game Boy Color
      mgba # Game Boy Advance
      melondsds # DS
      # Sega
      genesis-plus-gx # Master System, Game Gear, Genesis, Sega CD
      picodrive # 32X
      beetle-saturn # Saturn
      flycast # Dreamcast
      # Sony
      beetle-psx
      beetle-psx-hw # PS1 (the default here, for upscaling)
      swanstation
      ppsspp # PSP
      # NEC, SNK, Bandai
      beetle-pce # PC Engine / TurboGrafx-16, and their CD add-ons
      beetle-ngp # Neo Geo Pocket (Color)
      beetle-wswan # WonderSwan (Color)
      neocd # Neo Geo CD
      fbneo # arcade: Neo Geo, CPS1/2/3 and the rest of FinalBurn Neo
    ];
    settings = {
      system_directory = bios;
      input_joypad_driver = "sdl2";
      input_menu_toggle_gamepad_combo = "2";
      input_quit_gamepad_combo = "4";
      video_driver = "vulkan";
      global_core_options = "true";
      core_options_path = "${retroarchCoreOptionsFile}";
    };
  };

  retroarchCoreOptions = {
    beetle-psx-hw = {
      beetle_psx_hw_internal_resolution = "8x";
      beetle_psx_hw_pgxp_mode = "memory only";
      beetle_psx_hw_pgxp_texture = "enabled";
      beetle_psx_hw_dither_mode = "disabled";
      beetle_psx_hw_depth = "32bpp";
    };
    mupen64plus = {
      mupen64plus-rdp-plugin = "parallel";
      mupen64plus-rsp-plugin = "parallel";
      mupen64plus-parallel-rdp-upscaling = "4x";
    };
    flycast = {
      reicast_internal_resolution = "2880x2160";
    };
    ppsspp = {
      ppsspp_internal_resolution = "2880x1632";
    };
    melondsds = {
      melonds_screen_layout1 = "hybrid-top";
    };
  };

  retroarchCoreOptionsFile = pkgs.writeText "retroarch-core-options.cfg"
    (lib.concatStrings (lib.mapAttrsToList (k: v: "${k} = \"${v}\"\n")
      (lib.mergeAttrsList (lib.attrValues retroarchCoreOptions))));

  # Fails the build if a core no longer has an option key declared above —
  # RetroArch ignores an unknown key without a word.
  retroarchCoreOptionsCheck = pkgs.runCommand "retroarch-core-options-check" { } (
    lib.concatStrings (lib.mapAttrsToList (core: opts:
      lib.concatMapStrings (key: ''
        grep -qaF -- '${key}' ${pkgs.libretro.${core}}/lib/retroarch/cores/*.so \
          || { echo "libretro.${core} has no core option '${key}'" >&2; exit 1; }
      '') (lib.attrNames opts)) retroarchCoreOptions)
    + "touch $out\n");

  # ---- Standalone emulators ------------------------------------------------

  configMerge = pkgs.writeShellScript "emulation-config-merge" ''
    exec ${pkgs.python3.withPackages (ps: [ ps.tomlkit ])}/bin/python3 \
      ${./emulation-config-merge.py} "$@"
  '';

  # The package with each of `bins` wrapped to merge `spec` into its config
  # first. `aliases` are other names for a wrapped binary (Cemu ships `cemu`
  # as a symlink to `Cemu`), re-pointed so they cannot bypass the wrapper.
  configured = { pkg, bins, aliases ? { }, spec }:
    let specFile = pkgs.writeText "${pkg.pname}-config.json" (builtins.toJSON spec);
    in pkgs.symlinkJoin {
      name = "${pkg.pname}-configured-${pkg.version}";
      paths = [ pkg ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = lib.concatMapStrings (bin: ''
        rm "$out/bin/${bin}"
        makeWrapper ${pkg}/bin/${bin} "$out/bin/${bin}" --run "${configMerge} ${specFile}"
      '') bins
      + lib.concatStrings (lib.mapAttrsToList (alias: target: ''
        ln -sfn ${target} "$out/bin/${alias}"
      '') aliases);
      inherit (pkg) meta;
    };

  pcsx2 = configured {
    pkg = pkgs.pcsx2;
    bins = [ "pcsx2-qt" ];
    spec = [{
      format = "ini";
      path = "${home}/.config/PCSX2/inis/PCSX2.ini";
      set = {
        UI = {
          SetupWizardIncomplete = "false";
          StartFullscreen = "true";
          ConfirmShutdown = "false";
          HideMouseCursor = "true";
        };
        Folders.Bios = bios;
        "EmuCore/GS" = {
          Renderer = "14";
          upscale_multiplier = "4";
        };
        EmuCore = {
          EnableWideScreenPatches = "true";
          EnableNoInterlacingPatches = "true";
        };
      };
      seed = {
        UI.SettingsVersion = "1";
        # SDL's game-controller names for the first pad — in Gaming Mode
        # always Steam's virtual pad, so the index never moves.
        Pad1 = {
          Type = "DualShock2";
          Up = "SDL-0/DPadUp";
          Right = "SDL-0/DPadRight";
          Down = "SDL-0/DPadDown";
          Left = "SDL-0/DPadLeft";
          Triangle = "SDL-0/Y";
          Circle = "SDL-0/B";
          Cross = "SDL-0/A";
          Square = "SDL-0/X";
          Select = "SDL-0/Back";
          Start = "SDL-0/Start";
          L1 = "SDL-0/LeftShoulder";
          R1 = "SDL-0/RightShoulder";
          L2 = "SDL-0/+LeftTrigger";
          R2 = "SDL-0/+RightTrigger";
          L3 = "SDL-0/LeftStick";
          R3 = "SDL-0/RightStick";
          LUp = "SDL-0/-LeftY";
          LRight = "SDL-0/+LeftX";
          LDown = "SDL-0/+LeftY";
          LLeft = "SDL-0/-LeftX";
          RUp = "SDL-0/-RightY";
          RRight = "SDL-0/+RightX";
          RDown = "SDL-0/+RightY";
          RLeft = "SDL-0/-RightX";
          LargeMotor = "SDL-0/LargeMotor";
          SmallMotor = "SDL-0/SmallMotor";
        };
        Hotkeys = {
          OpenPauseMenu = "SDL-0/LeftStick & SDL-0/RightStick";
          ShutdownVM = "SDL-0/Back & SDL-0/Start";
        };
      };
    }];
  };

  dolphin = configured {
    pkg = pkgs.dolphin-emu;
    bins = [ "dolphin-emu" ];
    spec = [
      {
        format = "ini";
        path = "${home}/.config/dolphin-emu/Dolphin.ini";
        set = {
          Core.GFXBackend = "Vulkan";
          Display.Fullscreen = "True";
          Interface.ConfirmStop = "False";
          Analytics = {
            PermissionAsked = "True";
            Enabled = "False";
          };
        };
      }
      {
        format = "ini";
        path = "${home}/.config/dolphin-emu/GFX.ini";
        set.Settings.InternalResolution = "4";
      }
    ];
  };

  cemu = configured {
    pkg = pkgs.cemu;
    bins = [ "Cemu" ];
    aliases.cemu = "Cemu";
    spec = [{
      format = "xml";
      root = "content";
      path = "${home}/.config/Cemu/settings.xml";
      set = {
        fullscreen = "true";
        check_update = "false";
        "Graphic/api" = "1"; # 0 OpenGL, 1 Vulkan
      };
    }];
  };

  azahar = configured {
    pkg = pkgs.azahar;
    bins = [ "azahar" ];
    spec = [{
      format = "qtini";
      path = "${home}/.config/azahar-emu/qt-config.ini";
      set = {
        UI = {
          fullscreen = "true";
          confirmClose = "false";
          firstStart = "false";
          hideInactiveMouse = "true";
        };
        Renderer = {
          graphics_api = "2"; # 0 software, 1 OpenGL, 2 Vulkan
          resolution_factor = "4";
        };
      };
      seed.Layout.layout_option = "2"; # Large screen
    }];
  };

  xemu = configured {
    pkg = pkgs.xemu;
    bins = [ "xemu" ];
    spec = [{
      format = "toml";
      path = "${home}/.local/share/xemu/xemu/xemu.toml";
      set = {
        general.show_welcome = false;
        display = {
          renderer = "VULKAN";
          window.fullscreen_on_startup = true;
          quality.surface_scale = 3;
        };
        sys.files = {
          bootrom_path = "${bios}/xbox/mcpx_1.0.bin";
          flashrom_path = "${bios}/xbox/Complex_4627.bin";
          hdd_path = "${home}/.local/share/xemu/xemu/xbox_hdd.qcow2";
        };
      };
    }];
  };

  standaloneEmulators = [ pcsx2 dolphin cemu azahar xemu ];

  # ---- ES-DE ---------------------------------------------------------------

  # Systems meant to have games. esdeCheck verifies each one's default
  # emulator is installed; a system missing here is simply unchecked.
  esdeSystems = [
    "nes" "snes" "n64" "gb" "gbc" "gba" "nds" "n3ds" "gc" "wii" "wiiu"
    "mastersystem" "gamegear" "genesis" "megadrive" "segacd" "megacd" "sega32x"
    "saturn" "dreamcast"
    "psx" "ps2" "psp"
    "xbox"
    "pcengine" "pcenginecd" "tg16" "tg-cd"
    "ngp" "ngpc" "wonderswan" "wonderswancolor"
    "arcade" "fbneo" "neogeo" "neogeocd" "cps" "cps1" "cps2" "cps3"
  ];

  # System → the label of the <command> to make its default, where ES-DE's
  # own first choice is wrong for terra. Installed as
  # ~/ES-DE/custom_systems/es_systems.xml: a custom system of the same name
  # replaces the bundled one, so each entry is the bundled system regenerated
  # at build time with that command moved first — a new ES-DE keeps its own
  # extensions and commands, and the build fails if a system or label
  # disappears. A per-system or per-game alternative emulator picked in
  # ES-DE's UI is stored in gamelist.xml and wins over this.
  esdeDefaultEmulators = {
    psx = "Beetle PSX HW"; # default Beetle PSX cannot upscale
    ps2 = "PCSX2 (Standalone)"; # default PCEE2 core is not in nixpkgs
    gc = "Dolphin (Standalone)"; # default Dolphin core lags upstream
    wii = "Dolphin (Standalone)";
    n3ds = "Azahar (Standalone)"; # default Azahar core is not in nixpkgs
    # default MAME — see the header
    arcade = "FinalBurn Neo";
    cps = "FinalBurn Neo";
    cps1 = "FinalBurn Neo";
    cps2 = "FinalBurn Neo";
    cps3 = "FinalBurn Neo";
  };

  esdeCustomSystems = pkgs.runCommand "es-de-custom-systems.xml"
    { nativeBuildInputs = [ pkgs.python3 ]; } ''
    python3 - ${es-de.systems} ${pkgs.writeText "es-de-defaults.json" (builtins.toJSON esdeDefaultEmulators)} > $out <<'EOF'
    import json, sys, xml.etree.ElementTree as ET
    bundled = {s.findtext("name"): s for s in ET.parse(sys.argv[1]).getroot().iter("system")}
    out = ET.Element("systemList")
    for name, label in sorted(json.load(open(sys.argv[2])).items()):
        if name not in bundled:
            sys.exit(f"ES-DE has no system {name!r}")
        system = bundled[name]
        commands = system.findall("command")
        chosen = [c for c in commands if c.get("label") == label]
        if not chosen:
            sys.exit(f"ES-DE system {name!r} has no command labelled {label!r}")
        if chosen[0] is not commands[0]:
            system.remove(chosen[0])
            system.insert(list(system).index(commands[0]), chosen[0])
        out.append(system)
    ET.indent(out)
    print('<?xml version="1.0"?>')
    print(ET.tostring(out, encoding="unicode"))
    EOF
  '';

  # Every system in esdeSystems must launch something that exists: its first
  # command's core in RetroArch's cores dir, or its %EMULATOR_X% under one of
  # the names ES-DE's find rules search PATH for.
  esdeCheck = pkgs.runCommand "es-de-default-emulators-check"
    { nativeBuildInputs = [ pkgs.python3 ]; } ''
    python3 - <<'EOF'
    import os, re, sys, xml.etree.ElementTree as ET
    def systems(path):
        return {s.findtext("name"): s for s in ET.parse(path).getroot().iter("system")}
    effective = systems("${es-de.systems}") | systems("${esdeCustomSystems}")
    rules = {e.get("name"): [x.text for r in e.findall("rule") if r.get("type") == "systempath"
                             for x in r.findall("entry")]
             for e in ET.parse("${es-de.findRules}").getroot().iter("emulator")}
    cores = "${retroarch}/lib/retroarch/cores"
    bindirs = ["${retroarch}/bin"] + "${lib.concatMapStringsSep " " (p: "${p}/bin") standaloneEmulators}".split()
    errors = []
    for name in "${lib.concatStringsSep " " esdeSystems}".split():
        if name not in effective:
            errors.append(f"{name}: ES-DE has no such system")
            continue
        command = effective[name].find("command")
        label, text = command.get("label"), command.text
        core = re.search(r"%CORE_RETROARCH%/(\S+?\.so)", text)
        if core and not os.path.exists(os.path.join(cores, core.group(1))):
            errors.append(f"{name}: default {label!r} needs core {core.group(1)}, not installed")
        for emulator in re.findall(r"%EMULATOR_([^%]+)%", text):
            names = rules.get(emulator, [])
            if not any(os.path.exists(os.path.join(d, n)) for d in bindirs for n in names):
                errors.append(f"{name}: default {label!r} needs {emulator} ({', '.join(names)}), not installed")
    if errors:
        sys.exit("\n".join(errors))
    EOF
    touch $out
  '';
in
{
  environment.systemPackages = [ es-de retroarch ] ++ standaloneEmulators;

  home-manager.users.brian = { config, ... }: {
    home.file = {
      "ES-DE/custom_systems/es_systems.xml".source = esdeCustomSystems;

      # The PPSSPP core reads its fonts, system-dialog atlas and language
      # files from <system dir>/PPSSPP and ships none of them; nixpkgs'
      # standalone ppsspp carries the same asset tree. `recursive` links each
      # file into real directories, because the core also writes there
      # (PSP saves go to RetroArch's saves dir, not here).
      "ES-DE/bios/PPSSPP" = {
        source = "${pkgs.ppsspp}/share/ppsspp/assets";
        recursive = true;
      };

      # Cemu only looks for keys.txt in its own data dir; keep the real file
      # with the other BIOS files, where it is backed up.
      ".local/share/Cemu/keys.txt".source =
        config.lib.file.mkOutOfStoreSymlink "${bios}/wiiu/keys.txt";
    };

    # restic fails a run on a path that does not exist, and most of these
    # appear only once an emulator first starts. Directories only, created as
    # brian — every emulator here is fine finding its own directory already
    # there.
    home.activation.emulationDirs = config.lib.dag.entryAfter [ "writeBoundary" ] ''
      run mkdir -p ${lib.escapeShellArgs (backupPaths ++ [ "${bios}/wiiu" "${bios}/xbox" "${bios}/dc" "${bios}/neocd" ])}
    '';
  };

  system.checks = [ retroarchCoreOptionsCheck esdeCheck ];

  # ---------------------------------------------------------------------------
  # Backups
  # ---------------------------------------------------------------------------
  #
  # Saves, the emulators' own configs (they hold the controller maps that are
  # not in Nix), ES-DE's gamelists/collections/settings and the BIOS folder.
  # NOT the ROMs or the 19 GB of scraped media: both have a plain copy on
  # erebor (backups/terra/), and media can be re-scraped. Schedule and repo
  # location are in hosts/terra.nix — terra sleeps through 03:00.
  homelab.backup.paths = backupPaths;
  homelab.backup.exclude = map (p: "${home}/${p}") [
    # caches, captures and texture packs — regenerable or large
    ".config/retroarch/thumbnails"
    ".config/PCSX2/cache"
    ".config/PCSX2/covers"
    ".config/PCSX2/logs"
    ".config/PCSX2/resources"
    ".config/PCSX2/snaps"
    ".config/PCSX2/textures"
    ".config/PCSX2/videos"
    ".local/share/dolphin-emu/Cache"
    ".local/share/dolphin-emu/Dump"
    ".local/share/dolphin-emu/Load"
    ".local/share/dolphin-emu/Logs"
    ".local/share/dolphin-emu/ScreenShots"
    ".local/share/azahar-emu/dump"
    ".local/share/azahar-emu/load"
    ".local/share/azahar-emu/log"
    ".local/share/azahar-emu/shaders"
    # installed 3DS titles (CIA contents) — saves sit beside them in data/
    ".local/share/azahar-emu/sdmc/Nintendo 3DS/*/*/title/*/*/content"
  ];
}
