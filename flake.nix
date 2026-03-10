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
  };

  nixConfig = {
    extra-substituters = [ "https://nixos-raspberrypi.cachix.org" ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };

  outputs = { self, nixpkgs, nixos-raspberrypi, disko, sops-nix, home-manager, ... }@inputs:
    let
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
      ] ++ extraModules;
    in
    {
    nixosConfigurations = {
      pirateship = nixos-raspberrypi.lib.nixosSystem {
        modules = piModules [
          ./hosts/pirateship.nix
          ./modules/arr-stack.nix
          ./modules/monitoring.nix
        ];
        specialArgs = { inherit inputs nixos-raspberrypi; };
      };

      rivendell = nixos-raspberrypi.lib.nixosSystem {
        modules = piModules [
          ./hosts/rivendell.nix
          ./modules/dns.nix
          ./modules/homeassistant.nix
          ./modules/proxy.nix
          ./modules/monitoring.nix
          ./modules/nut.nix
          ./modules/ntfy.nix
          ./modules/uptime-kuma.nix
        ];
        specialArgs = { inherit inputs nixos-raspberrypi; };
      };

      mirkwood = nixos-raspberrypi.lib.nixosSystem {
        modules = piModules [
          ./hosts/mirkwood.nix
          ./modules/dns.nix
          ./modules/homepage.nix
          ./modules/monitoring.nix
        ];
        specialArgs = { inherit inputs nixos-raspberrypi; };
      };
    };
  };
}
