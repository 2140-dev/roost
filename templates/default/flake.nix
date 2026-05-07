{
  description = "Frigate deployment scaffold";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nix-bitcoin.url = "github:fort-nix/nix-bitcoin/release";
    nix-bitcoin.inputs.nixpkgs.follows = "nixpkgs";

    roost.url = "github:josibake/roost";
    roost.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nix-bitcoin,
      roost,
    }:
    {
      nixosConfigurations.frigate-host = nixpkgs.lib.nixosSystem {
        # FIXME: set to match your target hardware.
        system = "x86_64-linux";
        modules = [
          nix-bitcoin.nixosModules.default
          roost.nixosModules.frigate
          ./configuration.nix
        ];
      };
    };
}
