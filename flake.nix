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
    # dotfiles is the source of home configs; use its pinned home-manager so
    # both flakes always run the same HM version against the same nixpkgs.
    dotfiles.url = "github:bcrescimanno/dotfiles";
    home-manager.follows = "dotfiles/home-manager";
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  nixConfig = {
    extra-substituters = [
      "https://nixos-raspberrypi.cachix.org"
      "https://cache.theshire.io"
    ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
      # TODO: add attic signing public key after first deployment (step 4 in modules/attic.nix)
      # "cache.theshire.io-1:<base64-public-key>"
    ];
  };

  outputs = { self, nixpkgs, nixos-raspberrypi, disko, sops-nix, home-manager, deploy-rs, ... }@inputs:
    let
      # Not secret — appears in R2 endpoint URLs. Set this to your Cloudflare account ID.
      r2AccountId = "e10a637fb9ef49068ff75e106b7a7c19";

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
          # glances test_phys_core_returns_int fails on aarch64 in the Nix
          # sandbox because psutil.cpu_count(logical=False) returns None when
          # CPU topology is unavailable. Deselect the specific test via
          # pytestFlagsArray — runtime is unaffected.
          # test_restful and test_xmlrpc require a running server/network
          # connection that the sandbox blocks; ignore the entire files.
          nixpkgs.overlays = [
            (final: prev: {
              glances = prev.glances.overrideAttrs (oldAttrs: {
                pytestFlagsArray = (oldAttrs.pytestFlagsArray or []) ++ [
                  "--deselect=tests/test_plugin_load.py::TestLoadHelperFunctions::test_phys_core_returns_int"
                  "--ignore=tests/test_restful.py"
                  "--ignore=tests/test_xmlrpc.py"
                ];
              });
            })
          ];
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
        }
        ./modules/base.nix
        ./modules/backup.nix
      ] ++ extraModules;

      # deploy-rs activate helper for aarch64-linux (all three Pis)
      activate = deploy-rs.lib.aarch64-linux.activate.nixos;

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
          ./modules/monitoring.nix
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
          ./modules/attic.nix
        ];
        specialArgs = { inherit inputs nixos-raspberrypi r2AccountId; };
      };
    };

    deploy.nodes = {
      pirateship = piProfile "pirateship.home.theshire.io" self.nixosConfigurations.pirateship;
      rivendell  = piProfile "rivendell.home.theshire.io"  self.nixosConfigurations.rivendell;
      mirkwood   = piProfile "mirkwood.home.theshire.io"   self.nixosConfigurations.mirkwood;
    };

  };
}
