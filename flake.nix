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
  };

  nixConfig = {
    extra-substituters = [ "https://nixos-raspberrypi.cachix.org" ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };

  outputs = { self, nixpkgs, nixos-raspberrypi, disko, sops-nix, ... }@inputs:
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
        ./modules/base.nix
      ] ++ extraModules;
    in
    {
    nixosConfigurations = {
      pirateship = nixos-raspberrypi.lib.nixosSystem {
        modules = piModules [
          ./hosts/pirateship.nix
          ./modules/arr-stack.nix
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
