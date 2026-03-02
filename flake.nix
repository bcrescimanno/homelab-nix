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

  outputs = { self, nixpkgs, nixos-raspberrypi, disko, sops-nix, ... }@inputs: {
    nixosConfigurations = {
      pirateship = nixos-raspberrypi.lib.nixosSystem {
        modules = [
          ({ ... }: {
            imports = with nixos-raspberrypi.nixosModules; [
              raspberry-pi-5.base
              raspberry-pi-5.bluetooth
            ];
          })
          disko.nixosModules.disko
          ./hosts/pirateship.nix
          ./modules/base.nix
          sops-nix.nixosModules.sops
        ];
        specialArgs = { inherit inputs nixos-raspberrypi; };
      };
    };
  };
}
