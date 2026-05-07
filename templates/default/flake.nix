{
  description = "Frigate deployment scaffold";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    roost.url = "github:2140-dev/roost";
    roost.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      roost,
    }:
    {
      nixosConfigurations.frigate-host = nixpkgs.lib.nixosSystem {
        # FIXME: set to match your target hardware.
        system = "x86_64-linux";
        modules = [
          roost.nixosModules.default
          ./configuration.nix
        ];
      };
    };
}
