# roost

Reusable NixOS modules and packaging for [Frigate](https://github.com/sparrowwallet/frigate),
the silent payments scanning server used by Sparrow Wallet.

## Status

Alpha. The public API may change.

## What it provides

- `nixosModules.frigate` — service module for Frigate. Typed options, no opinions about its dependencies.
- `nixosModules.hetzner-bare-metal` — bootloader and `network-online` workarounds for Hetzner bare metal.
- `packages.<system>.frigate` — the Frigate package (Linux and macOS).
- `overlays.default` — exposes `pkgs.frigate`.
- `lib.mkRegtestE2E` — VM-based regtest end-to-end test, parameterizable for downstream consumers.
- `templates.default` — a starting point for a deployment.

## Quick start

Add `roost` and `nix-bitcoin` to your flake inputs:

```nix
inputs = {
  nixpkgs.url      = "github:NixOS/nixpkgs/nixos-unstable";
  nix-bitcoin.url  = "github:fort-nix/nix-bitcoin/release";
  nix-bitcoin.inputs.nixpkgs.follows = "nixpkgs";
  roost.url        = "github:josibake/roost";
  roost.inputs.nixpkgs.follows = "nixpkgs";
};
```

In a NixOS configuration:

```nix
{
  imports = [
    nix-bitcoin.nixosModules.default
    roost.nixosModules.frigate
  ];

  services.bitcoind = {
    enable  = true;
    txindex = true;
    dataDirReadableByGroup = true;
  };

  services.electrs.enable = true;

  services.frigate = {
    enable           = true;
    host             = "frigate.example.com";
    bitcoind.cookieDir = "/var/lib/bitcoind";
  };

  users.users.frigate.extraGroups = [ "bitcoin" ];
}
```

A working scaffold with FIXME markers is available via:

```
nix flake init -t github:josibake/roost
```

## Tests

```
nix flake check
```

runs `regtest-e2e`, a VM that brings up bitcoind, electrs, and frigate on regtest, mines 101 blocks, and verifies frigate answers an Electrum-protocol query.

Downstream consumers can run the same test against their own configuration:

```nix
checks.x86_64-linux.frigate = roost.lib.mkRegtestE2E {
  pkgs        = nixpkgs.legacyPackages.x86_64-linux;
  nix-bitcoin = nix-bitcoin;
  extraModules = [ ./my-host.nix ];
};
```

## License

MIT. See [LICENSE](LICENSE).
