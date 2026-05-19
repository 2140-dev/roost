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
        public-frigate = ./modules/presets/public-frigate.nix;
        frigate-edge = ./modules/presets/frigate-edge.nix;
        wireguard-mesh = ./modules/wireguard-mesh.nix;

        # Batteries-included entry point. Bundles nix-bitcoin so the
        # consumer needs only `roost` in their flake inputs to deploy a
        # complete public Frigate node, and turns on the preset's manage
        # flags so bitcoind and fulcrum are configured automatically.
        # Use `nixosModules.public-frigate` directly if you operate
        # bitcoind/fulcrum out of band.
        default = {
          imports = [
            nix-bitcoin.nixosModules.default
            ./modules/presets/public-frigate.nix
          ];
          services.public-frigate = {
            bitcoind.manage = nixpkgs.lib.mkDefault true;
            fulcrum.manage = nixpkgs.lib.mkDefault true;
          };
        };
      };

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-tree);

      lib = {
        # VM-based end-to-end regtest against the bare frigate module.
        # Parameterized so downstream consumers can run the same scenario
        # with their own modules layered on top.
        mkRegtestE2E =
          {
            pkgs,
            nix-bitcoin,
            extraModules ? [ ],
          }:
          import ./test/regtest-e2e.nix { inherit pkgs nix-bitcoin extraModules; };

        # End-to-end test against `nixosModules.default` (the preset path
        # with bitcoind/electrs/nginx-TLS managed automatically). The roost
        # flake is captured here from the surrounding closure so consumers
        # do not have to thread it through themselves.
        mkRegtestPresetE2E =
          {
            pkgs,
            extraModules ? [ ],
          }:
          import ./test/regtest-preset.nix {
            inherit pkgs extraModules;
            roost = self;
          };

        # Two-node test of the wireguard-mesh module. Boots two VMs on
        # the test driver's shared virtual network, brings up the mesh,
        # and verifies cross-mesh reachability + firewall scoping.
        mkMeshTest =
          {
            pkgs,
            extraModules ? [ ],
          }:
          import ./test/mesh.nix {
            inherit pkgs extraModules;
            roost = self;
          };

        # Two-VM end-to-end test for the frigate-edge preset. Boots a
        # full nix-bitcoin stack on the `backend` node (with the
        # public-frigate exposeBackends option enabled) and a slim
        # frigate-edge consumer on the `edge` node, then exercises the
        # edge's Electrum listeners.
        mkRegtestEdgeE2E =
          {
            pkgs,
            extraModules ? [ ],
          }:
          import ./test/regtest-edge.nix {
            inherit pkgs extraModules;
            roost = self;
          };
      };

      checks = forAllLinux (system: {
        regtest-e2e = self.lib.mkRegtestE2E {
          pkgs = pkgsFor system;
          inherit nix-bitcoin;
        };
        regtest-preset = self.lib.mkRegtestPresetE2E {
          pkgs = pkgsFor system;
        };
        regtest-edge = self.lib.mkRegtestEdgeE2E {
          pkgs = pkgsFor system;
        };
        wireguard-mesh = self.lib.mkMeshTest {
          pkgs = pkgsFor system;
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
