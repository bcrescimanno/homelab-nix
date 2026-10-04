{
  description = "Homelab NixOS configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # Track `nixos-unstable` (not `main`): we run nixpkgs-unstable, and this is
    # nixos-raspberrypi's companion branch for that channel, so the two move
    # together. The stable `main` branch lags — it froze at 2026-05-17 with an
    # unguarded `boot.loader.kernelFile = …stdenv.hostPlatform.linux-kernel.target`,
    # which broke once nixpkgs 26.11 removed that attribute. nixos-unstable carries
    # the version-guarded fix.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/nixos-unstable";
    nixos-raspberrypi.inputs.nixpkgs.follows = "nixpkgs";

    # Same flake, deliberately NOT following our nixpkgs. Making nixos-raspberrypi
    # follow ours changes the kernel's derivation hash, so the prebuilt kernel in
    # nixos-raspberrypi.cachix.org never matches and every nixpkgs bump forces a
    # multi-hour from-source kernel build on the Pi itself. Measured 2026-07-31:
    # identical version 6.18.34-unstable_20260604, upstream's hash cached (200),
    # ours uncached (404 in cachix, attic and cache.nixos.org alike).
    #
    # Taking only boot.kernelPackages from this un-followed instance makes the
    # kernel a download again while userland stays on our current nixpkgs.
    nixos-raspberrypi-cached.url = "github:nvmd/nixos-raspberrypi/nixos-unstable";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # home-manager: homelab-nix owns this pin; dotfiles follows it when consumed
    # here so both always run the same HM version against the same nixpkgs.
    # dotfiles continues to declare its own home-manager for standalone use.
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    dotfiles.url = "github:bcrescimanno/dotfiles";
    dotfiles.inputs.nixpkgs.follows = "nixpkgs";
    dotfiles.inputs.home-manager.follows = "home-manager";
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  nixConfig = {
    extra-substituters = [
      "https://nixos-raspberrypi.cachix.org"
      "https://cache.theshire.io/nixpkgs"
    ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
      "nixpkgs:4zoHH4lPBJuJfPmH0/FjKl5yIYfG0yCZc39m492t+jM="
    ];
  };

  outputs = { self, nixpkgs, nixos-raspberrypi, disko, sops-nix, home-manager, deploy-rs, ... }@inputs:
    let
      # Systems we can build the standalone packages below for. aarch64 is what
      # actually runs them; x86_64 exists so the pin-refresh tooling and a local
      # `nix build` work without a Pi.
      pkgSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs pkgSystems (system: f nixpkgs.legacyPackages.${system});

      # Not secret — appears in R2 endpoint URLs. Set this to your Cloudflare account ID.
      r2AccountId = "e10a637fb9ef49068ff75e106b7a7c19";
      brianSshKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBEjcQUPpiMkeQJFlkrERftafbT/CpjaeRzbHUv/0P2W";

      # glances test failures in the Nix sandbox:
      # - test_phys_core_returns_int: psutil.cpu_count(logical=False) returns None on aarch64 (no CPU topology)
      # - test_api.py, test_memoryleak.py: psutil.net_if_stats() → ioctl(SIOCETHTOOL) fails in sandbox
      # - test_restful / test_xmlrpc / test_browser_restful: require a running server/network
      # - test_core.py: test_000_update fails in sandbox (no real system stats available)
      glancesOverlay = final: prev: {
        glances = prev.glances.overrideAttrs (oldAttrs: {
          pytestFlagsArray = (oldAttrs.pytestFlagsArray or []) ++ [
            "--deselect=tests/test_plugin_load.py::TestLoadHelperFunctions::test_phys_core_returns_int"
            "--ignore=tests/test_api.py"
            "--ignore=tests/test_browser_restful.py"
            "--ignore=tests/test_core.py"
            "--ignore=tests/test_memoryleak.py"
            "--ignore=tests/test_restful.py"
            "--ignore=tests/test_xmlrpc.py"
          ];
        });
      };

      # numkong 7.8.3 (usearch → music-assistant, so rivendell) does not compile
      # on aarch64 under GCC 16: GCC inlines the streaming-SVE helpers into SME
      # kernels whose target pragma is only "+sme", then rejects the SVE
      # intrinsics ("ACLE function 'svwhilelt_b64_u64' requires ISA extension
      # 'sve'"). GCC 15 accepted it. Not LTO — it fails with IPO off too.
      # Backports the upstream fix (ashvardanian/NumKong#389, released in
      # v7.8.4). Pi-only: x86_64 never compiles these kernels. Remove once
      # nixpkgs ships numkong >= 7.8.4 — the patch will then fail to apply,
      # which is the intended signal.
      #
      # The patch goes on `src`, not `patches`: python3Packages.numkong builds
      # from `pkgs.numkong.src` and usearch symlinks `numkong.src` in as its
      # vendored copy, so a `patches` override leaves both of those broken.
      numkongOverlay = final: prev: {
        numkong = prev.numkong.overrideAttrs (oldAttrs: {
          src = final.applyPatches {
            src = oldAttrs.src;
            patches = [
              (final.fetchpatch {
                name = "numkong-gcc16-sme-out-of-line.patch";
                url = "https://github.com/ashvardanian/NumKong/commit/de1da85240e4ff4b29890cfb290103ddee5bf9c2.patch";
                hash = "sha256-EQM3TRs4B4vUHhE3xD2IHHpaV3pz1+dpPRrFxhRqzes=";
              })
            ];
          };
        });
      };

      # torchaudio (beat-this → music-assistant, so rivendell) is not cached
      # for aarch64: every Hydra build since the GCC 16 bump (2026-09-29 on)
      # ended "Log limit exceeded", so rivendell compiles it itself. The
      # compile is fine; the pytest suite climbs past 5 GB RSS and is
      # OOM-killed on an 8 GB Pi. Skip the tests. Droppable once Hydra caches
      # it again — the unpatched build then substitutes instead of building.
      torchaudioOverlay = final: prev: {
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (pyFinal: pyPrev: {
            torchaudio = pyPrev.torchaudio.overridePythonAttrs { doCheck = false; };
          })
        ];
      };

      # Two music-assistant AirPlay tests assume a 176400-byte write overflows
      # the pipe buffer. That holds on 4K-page kernels (64 KiB buffer), but the
      # Pi 5 kernel uses 16K pages, the buffer is 256 KiB, the write fits, and
      # both fail with `assert True is False`. Deterministic, not a race, and
      # Hydra's 4K-page builders never see it — it only surfaces when the
      # numkong/torchaudio overlays above force a local build. Remove when
      # those two go and music-assistant substitutes from cache again.
      # overrideAttrs, NOT overridePythonAttrs: the latter drops `.override`,
      # which the upstream module (finalPackage) and ours (PYTHONPATH) call.
      musicAssistantOverlay = final: prev: {
        music-assistant = prev.music-assistant.overrideAttrs (oldAttrs: {
          disabledTests = (oldAttrs.disabledTests or []) ++ [
            "test_pipe_write_reports_a_stalled_reader_without_raising"
            "test_pipe_write_resets_fd_when_the_reader_closes_during_a_stall"
          ];
        });
      };

      commonOverlays = [ glancesOverlay ];
      piOverlays = commonOverlays ++ [ numkongOverlay torchaudioOverlay musicAssistantOverlay ];

      # Every overlay above is a workaround for an upstream bug, and every one
      # of their comments ends with some form of "remove once nixpkgs fixes it".
      # Nothing checked, so they accrued — and the dangerous direction is silent:
      # an overlay that is no longer NEEDED keeps applying forever, disabling
      # tests that would now pass. Same shape as a redundant --replace-fail patch
      # in pkgs/materialious.nix.
      #
      # This list is the machine-checkable form of that question.
      # scripts/check-overlays builds each package UNPATCHED against the current
      # lock; a clean build means the overlay can go. Adding an overlay without
      # adding it here is the mistake to avoid.
      #
      # `arch` records where the failure the overlay works around actually
      # occurs, because that determines where the probe is meaningful — the
      # entries below reproduce only on aarch64, so an x86_64 probe would
      # say nothing at all about whether they are still load-bearing.
      #
      # `flaky` records whether that failure is TIMING-DEPENDENT, and it changes
      # what a clean build is worth. For a deterministic failure — glances'
      # aarch64 psutil topology check — one clean build is proof the bug is
      # fixed. For a race, one clean build only proves the race was won that
      # time, which is the single-trial-on-an-intermittent-bug error, and acting
      # on it would reintroduce an overlay-shaped hole that fails a few builds
      # in a hundred.
      #
      # Marked entries must come back clean on every one of several forced
      # rebuilds before the probe will call them droppable. Both fields are
      # mandatory on every entry: an absent field would be read as a default,
      # and a default that silently means "not flaky" is the failure mode this
      # whole module exists to avoid.
      overlayWorkarounds = {
        glances = {
          arch = "aarch64";
          flaky = false;
          note = "sandbox + network-dependent tests; psutil topology returns None on aarch64";
        };
        numkong = {
          arch = "aarch64";
          flaky = false;
          note = "GCC 16 rejects SVE intrinsics inlined into +sme kernels; backports NumKong#389 (v7.8.4) onto numkong.src, which python3Packages.numkong and usearch also consume";
        };
        "python3Packages.torchaudio" = {
          arch = "aarch64";
          flaky = false;
          note = "no Hydra cache since GCC 16 (log limit exceeded); local pytest OOMs rivendell; tests skipped";
        };
        music-assistant = {
          arch = "aarch64";
          flaky = false;
          note = "2 AirPlay pipe-stall tests assume 64 KiB pipes; Pi 5 16K pages give 256 KiB; only bites on a local build";
        };
      };

      piModules = extraModules: [
        ({ lib, ... }: {
          imports = with nixos-raspberrypi.nixosModules; [
            raspberry-pi-5.base
            raspberry-pi-5.bluetooth
          ];

          # Take the kernel from the un-followed nixos-raspberrypi instance so it
          # resolves to upstream's cachix-cached build instead of being compiled
          # from source here. All three Pis are Pi 5s, so one package set covers
          # them. See the input comment above for the measured justification.
          boot.kernelPackages =
            lib.mkForce inputs.nixos-raspberrypi-cached.packages.aarch64-linux.linuxPackages_rpi5;
        })
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        home-manager.nixosModules.home-manager
        {
          nixpkgs.overlays = piOverlays;
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
        }
        ./modules/base.nix
        ./modules/backup.nix
      ] ++ extraModules;

      # deploy-rs activate helpers per architecture
      activate    = deploy-rs.lib.aarch64-linux.activate.nixos;
      activateX86 = deploy-rs.lib.x86_64-linux.activate.nixos;

      # Common deploy profile settings:
      # - sshUser: SSH as brian, sudo to root for activation
      # - remoteBuild: build on the Pi itself (avoids x86_64 → aarch64 cross-compilation)
      # - magicRollback: if activation breaks SSH, automatically roll back
      # - autoRollback: roll back if the activation script exits non-zero
      piProfile = hostname: config: {
        inherit hostname;
        profiles.system = {
          sshUser      = "brian";
          user         = "root";
          remoteBuild  = true;
          magicRollback = true;
          autoRollback  = true;
          fastConnection = true;
          path         = activate config;
        };
      };
    in
    {
    nixosConfigurations = {
      pirateship = nixos-raspberrypi.lib.nixosSystem {
        modules = piModules [
          ./hosts/pirateship.nix
          ./modules/arr-stack.nix
          ./modules/bazarr.nix
          ./modules/jellyfin-notify.nix
          ./modules/lidarr-formats.nix
          ./modules/monitoring.nix
          ./modules/music-sync.nix
          ./modules/nut-secondary.nix
          ./modules/navidrome.nix
          ./modules/qbittorrent-seed-policy.nix
          ./modules/vpn-killswitch.nix
          ./modules/vpn-port-reachability.nix
        ];
        specialArgs = { inherit inputs nixos-raspberrypi r2AccountId brianSshKey; };
      };

      rivendell = nixos-raspberrypi.lib.nixosSystem {
        modules = piModules [
          ./hosts/rivendell.nix
          ./modules/dns.nix
          ./modules/homeassistant.nix
          ./modules/ha-window-notifications.nix
          ./modules/ha-dashboard.nix
          ./modules/ha-bathroom-lights.nix
          ./modules/ha-hood-light.nix
          ./modules/ha-hvac-openings.nix
          ./modules/ha-pizza-preheat.nix
          ./modules/ha-daily-digest.nix
          ./modules/ha-chores.nix
          ./modules/caddy.nix
          ./modules/materialious.nix
          ./modules/monitoring.nix
          ./modules/nut.nix
          ./modules/ntfy.nix
          ./modules/gatus.nix
          ./modules/flake-freshness.nix
          ./modules/pr-automerge-watch.nix
          ./modules/music-assistant.nix
          ./modules/vaultwarden.nix
          ./modules/daily-digest.nix
          # github-runners.nix is not in nixos-raspberrypi's default module set
          "${nixpkgs}/nixos/modules/services/continuous-integration/github-runners.nix"
        ];
        specialArgs = { inherit inputs nixos-raspberrypi r2AccountId brianSshKey; };
      };

      mirkwood = nixos-raspberrypi.lib.nixosSystem {
        modules = piModules [
          ./hosts/mirkwood.nix
          ./modules/dns.nix
          ./modules/homepage.nix
          ./modules/monitoring.nix
          ./modules/nut-secondary.nix
          ./modules/grafana.nix
          ./modules/deadman.nix
        ];
        specialArgs = { inherit inputs nixos-raspberrypi r2AccountId brianSshKey; };
      };
      orthanc = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          {
            nixpkgs.overlays = commonOverlays;
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "backup";
          }
          ./modules/base.nix
          ./modules/backup.nix
          ./modules/monitoring.nix
          ./modules/nut-secondary.nix
          ./modules/minecraft.nix
          ./modules/jellyfin.nix
          ./modules/attic.nix
          ./modules/invidious.nix
          ./modules/deadman.nix
          ./modules/loki.nix
          ./hosts/orthanc.nix
        ];
        specialArgs = { inherit inputs r2AccountId brianSshKey; };
      };

      # Custom installer ISO for orthanc (x86_64).
      # Build: nix build .#nixosConfigurations.orthanc-installer.config.system.build.isoImage
      # Write:  sudo dd if=result/iso/*.iso of=/dev/sdX bs=4M status=progress oflag=sync
      orthanc-installer = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          {
            # SSH enabled with key auth so nixos-anywhere can connect remotely.
            services.openssh = {
              enable = true;
              settings = {
                PermitRootLogin = "yes";
                PasswordAuthentication = false;
              };
            };

            users.users.root.openssh.authorizedKeys.keys = [ brianSshKey ];

            # Suppress the "what are you trying to do?" nag on first boot.
            system.stateVersion = "25.11";
          }
        ];
      };
    };

    # Standalone packages. These are the two pins Renovate cannot see — a
    # fetchFromGitHub tag and a Go-module-graph FOD hash — and exposing them as
    # flake outputs is what lets scripts/refresh-pins update them without a
    # human transcribing hashes out of CI logs. Both are consumed by the NixOS
    # modules via callPackage on the same files, so there is one definition
    # each and the flake output cannot drift from what the hosts build.
    packages = forAllSystems (pkgs: {
      materialious     = pkgs.callPackage ./pkgs/materialious.nix { };
      caddy-cloudflare = pkgs.callPackage ./pkgs/caddy-cloudflare.nix { };
    });

    # Consumed by scripts/check-overlays. Kept as data next to the overlays it
    # describes so the two cannot drift; `nix flake show` will call this an
    # unknown output, same as `deploy` above, which is fine.
    inherit overlayWorkarounds;

    deploy.nodes = {
      pirateship = piProfile "pirateship.home.theshire.io" self.nixosConfigurations.pirateship;
      rivendell  = piProfile "rivendell.home.theshire.io"  self.nixosConfigurations.rivendell;
      mirkwood   = piProfile "mirkwood.home.theshire.io"   self.nixosConfigurations.mirkwood;
      orthanc = {
        hostname = "orthanc.home.theshire.io";
        profiles.system = {
          sshUser       = "brian";
          user          = "root";
          # x86_64: build locally (same arch as deploy machine), push result
          remoteBuild   = false;
          magicRollback = true;
          autoRollback  = true;
          fastConnection = true;
          path          = activateX86 self.nixosConfigurations.orthanc;
        };
      };
    };

  };
}
