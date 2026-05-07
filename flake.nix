{
  description = "Reusable NixOS modules and packaging for Frigate, the silent payments scanning server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nix-bitcoin.url = "github:fort-nix/nix-bitcoin/release";
    nix-bitcoin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nix-bitcoin,
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      forAllLinux = nixpkgs.lib.genAttrs linuxSystems;

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };
    in
    {
      overlays.default = final: _prev: {
        frigate = final.callPackage ./pkgs/frigate/package.nix { };
      };

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          frigate = pkgs.frigate;
          default = pkgs.frigate;
        }
      );

      nixosModules = {
        frigate = ./modules/frigate.nix;
        hetzner-bare-metal = ./modules/presets/hetzner-bare-metal.nix;
      };

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-tree);

      lib = {
        # VM-based end-to-end regtest. Parameterized so downstream consumers
        # can run the same scenario with their own modules layered on top.
        mkRegtestE2E =
          {
            pkgs,
            nix-bitcoin,
            extraModules ? [ ],
          }:
          import ./test/regtest-e2e.nix { inherit pkgs nix-bitcoin extraModules; };
      };

      checks = forAllLinux (system: {
        regtest-e2e = self.lib.mkRegtestE2E {
          pkgs = pkgsFor system;
          inherit nix-bitcoin;
        };
      });

      templates.default = {
        path = ./templates/default;
        description = "A starting point for a Frigate deployment";
      };

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.nixos-rebuild
              pkgs.nixos-anywhere
            ];
          };
        }
      );
    };
}
