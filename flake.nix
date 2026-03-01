{
  description = "Homelab NixOS configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, disko, nixos-hardware, ... }: {

    nixosConfigurations = {
      pirateship = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux"; 
        modules = [
          nixos-hardware.nixosModules.raspberry-pi-5
          disko.nixosModules.disko
          ./hosts/pirateship.nix
          ./modules/base.nix
        ];
      };
    };

  };
}
