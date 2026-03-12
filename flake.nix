{
  description = "Homelab NixOS configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";
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
    extra-substituters = [ "https://nixos-raspberrypi.cachix.org" ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
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
          # nixos-raspberrypi pins an older nixpkgs that predates
          # neovimUtils.makeVimPackageInfo. Overlay it in from the dotfiles
          # nixpkgs so home-manager's neovim module evaluation succeeds.
          nixpkgs.overlays = [
            (final: prev:
              let newerPkgs = inputs.dotfiles.inputs.nixpkgs.legacyPackages.${prev.system};
              in { neovimUtils = prev.neovimUtils // { inherit (newerPkgs.neovimUtils) makeVimPackageInfo; }; })
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
          ./modules/uptime-kuma.nix
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
    };

    deploy.nodes = {
      pirateship = piProfile "pirateship" self.nixosConfigurations.pirateship;
      rivendell  = piProfile "rivendell"  self.nixosConfigurations.rivendell;
      mirkwood   = piProfile "mirkwood"   self.nixosConfigurations.mirkwood;
    };
  };
}
