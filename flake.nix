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

      # prometheus-3.11.2 TestQueryLog race: HTTP server starts too slowly under qemu aarch64
      # emulation — "connection refused" on 127.0.0.1:34589 before server is ready.
      prometheusOverlay = final: prev: {
        prometheus = prev.prometheus.overrideAttrs (_: { doCheck = false; });
      };

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

      # music-assistant 2.9.9: test_digital_silence_yields_finite_spectral_centroid
      # errors with "RuntimeError: failed to initialize QNNPACK" — torch's quantized
      # backend can't initialise in the aarch64 Nix sandbox. 3113 tests pass; this is
      # the only environment-dependent failure. nixpkgs already disables four tests in
      # this same smart_fades module, so this extends an existing upstream workaround
      # rather than inventing one. Remove once nixpkgs disables it too.
      musicAssistantOverlay = final: prev: {
        music-assistant = prev.music-assistant.overrideAttrs (oldAttrs: {
          disabledTests = (oldAttrs.disabledTests or []) ++ [
            "test_digital_silence_yields_finite_spectral_centroid"
          ];
        });
      };

      # nixpkgs bumped elmPackages.elm 0.19.1 -> 0.19.2 on 2026-08-24 (#541199),
      # but alertmanager 0.33.1's ui/app/elm.json still pins "0.19.1". Elm matches
      # that field EXACTLY and aborts with "ELM VERSION MISMATCH", so
      # alertmanager-elm-ui fails to compile and takes mirkwood's whole closure
      # with it. This is an upstream nixpkgs regression, not arch-specific —
      # prometheus-alertmanager is broken on master on every platform.
      #
      # 0.19.2 is a performance-only patch release with no language changes, so
      # retargeting the pin is safe. elmUi is a `let` binding inside
      # package.nix, so overrideAttrs can't reach it — but it is re-exported as
      # passthru.elmUi, so patch that and re-point postPatch at the result.
      #
      # Remove once nixpkgs fixes alertmanager (watch pkgs/by-name/pr/prometheus-alertmanager).
      alertmanagerElmOverlay = final: prev:
        let
          patchedElmUi = prev.prometheus-alertmanager.elmUi.overrideAttrs (oldAttrs: {
            postPatch = (oldAttrs.postPatch or "") + ''
              substituteInPlace elm.json \
                --replace-fail '"elm-version": "0.19.1"' '"elm-version": "0.19.2"'
            '';
          });
        in
        {
          prometheus-alertmanager = prev.prometheus-alertmanager.overrideAttrs (_: {
            postPatch = "cp -r ${patchedElmUi}/. ui/app/dist";
          });
        };

      commonOverlays = [ glancesOverlay alertmanagerElmOverlay ];
      piOverlays = commonOverlays ++ [ prometheusOverlay musicAssistantOverlay ];

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
      # occurs, because that determines where the probe is meaningful — three of
      # these four reproduce only on aarch64.
      overlayWorkarounds = {
        glances = {
          arch = "aarch64";
          note = "sandbox + network-dependent tests; psutil topology returns None on aarch64";
        };
        prometheus = {
          arch = "aarch64";
          note = "TestQueryLog race: HTTP server too slow under qemu aarch64 emulation";
        };
        music-assistant = {
          arch = "aarch64";
          note = "torch QNNPACK will not initialise in the aarch64 sandbox";
        };
        prometheus-alertmanager = {
          arch = "any";
          note = "nixpkgs regression: elm 0.19.2 vs alertmanager's exact 0.19.1 pin";
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
          ./modules/navidrome.nix
          ./modules/qbittorrent-seed-policy.nix
          ./modules/vpn-killswitch.nix
        ];
        specialArgs = { inherit inputs nixos-raspberrypi r2AccountId brianSshKey; };
      };

      rivendell = nixos-raspberrypi.lib.nixosSystem {
        modules = piModules [
          ./hosts/rivendell.nix
          ./modules/dns.nix
          ./modules/homeassistant.nix
          ./modules/ha-window-notifications.nix
          ./modules/caddy.nix
          ./modules/materialious.nix
          ./modules/monitoring.nix
          ./modules/nut.nix
          ./modules/ntfy.nix
          ./modules/gatus.nix
          ./modules/music-assistant.nix
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
          ./modules/grafana.nix
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
          ./modules/minecraft.nix
          ./modules/jellyfin.nix
          ./modules/attic.nix
          ./modules/invidious.nix
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
