{
  description = "Homelab NixOS configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";
    nixos-raspberrypi.inputs.nixpkgs.follows = "nixpkgs";
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

      piModules = extraModules: [
        ({ ... }: {
          imports = with nixos-raspberrypi.nixosModules; [
            raspberry-pi-5.base
            raspberry-pi-5.bluetooth
          ];
        })
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        home-manager.nixosModules.home-manager
        {
          nixpkgs.overlays = [ glancesOverlay prometheusOverlay ];
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
        }
        ./modules/base.nix
        ./modules/backup.nix
        ./modules/remote-builder-client.nix
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
          ./modules/monitoring.nix
          ./modules/navidrome.nix
        ];
        specialArgs = { inherit inputs nixos-raspberrypi r2AccountId; };
      };

      rivendell = nixos-raspberrypi.lib.nixosSystem {
        modules = piModules [
          ./hosts/rivendell.nix
          ./modules/dns.nix
          ./modules/homeassistant.nix
          ./modules/caddy.nix
          ./modules/monitoring.nix
          ./modules/nut.nix
          ./modules/ntfy.nix
          ./modules/gatus.nix
          ./modules/music-assistant.nix
          ./modules/nixpkgs-watch.nix
        ];
        specialArgs = { inherit inputs nixos-raspberrypi r2AccountId; };
      };

      mirkwood = nixos-raspberrypi.lib.nixosSystem {
        modules = piModules [
          ./hosts/mirkwood.nix
          ./modules/dns.nix
          ./modules/homepage.nix
          ./modules/monitoring.nix
          ./modules/grafana.nix
        ];
        specialArgs = { inherit inputs nixos-raspberrypi r2AccountId; };
      };
      orthanc = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          {
            nixpkgs.overlays = [ glancesOverlay ];
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
          ./modules/piped.nix
          ./hosts/orthanc.nix
        ];
        specialArgs = { inherit inputs r2AccountId; };
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
