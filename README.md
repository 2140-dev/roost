# roost

Reusable NixOS modules and packaging for [Frigate](https://github.com/sparrowwallet/frigate),
the silent payments scanning server used by Sparrow Wallet.

## Status

Alpha. The public API may change.

## What it provides

- `nixosModules.default` — the "just works" entry point. Bundles
  [nix-bitcoin](https://github.com/fort-nix/nix-bitcoin), configures
  bitcoind and fulcrum, runs Frigate, and terminates Electrum-over-TLS
  in nginx. The consumer enables it and sets a hostname.
- `nixosModules.public-frigate` — the same preset, loose-coupled. Use
  this when you operate bitcoind and fulcrum out of band; the preset
  asserts on their preconditions and configures everything else.
- `nixosModules.frigate` — the bare service module. Typed options, no
  opinions about its dependencies.
- `nixosModules.hetzner-bare-metal` — bootloader and `network-online`
  workarounds for Hetzner bare metal.
- `packages.<system>.frigate` — the Frigate package.
- `overlays.default` — exposes `pkgs.frigate`.
- `lib.mkRegtestE2E` — VM-based regtest end-to-end test against the
  bare module, parameterizable for downstream consumers.
- `lib.mkRegtestPresetE2E` — the same end-to-end test against
  `nixosModules.default`.
- `templates.default` — a starting point for a deployment.

## Quick start

Add `roost` to your flake inputs:

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  roost.url   = "github:2140-dev/roost";
  roost.inputs.nixpkgs.follows = "nixpkgs";
};
```

Import `nixosModules.default` and configure:

```nix
{
  imports = [ roost.nixosModules.default ];

  services.public-frigate = {
    enable = true;
    host   = "frigate.example.com";
    tls.acmeEmail = "ops@example.com";
  };
}
```

That is the whole deployment. nix-bitcoin's bitcoind and fulcrum are
pulled in automatically, configured for a public Frigate node, and
ACME issues a Let's Encrypt cert for the configured host.

A working scaffold with FIXME markers is available via:

```
nix flake init -t github:2140-dev/roost
```

## Binary cache

Pre-built outputs for `frigate` (and other roost derivations) are
published to Cachix at `https://2140-dev.cachix.org`. Configure your
system to use it once:

```
cachix use 2140-dev
```

Subsequent `nix build .#frigate` and `nixos-rebuild switch` invocations
pull the cached package instead of running the Gradle build locally.

## Bring your own bitcoind

If you operate bitcoind and fulcrum separately (for example, you
already have a hardened nix-bitcoin host and want to add Frigate to
it), use `nixosModules.public-frigate` instead. The preset asserts
that bitcoind is enabled with `txindex` and that fulcrum is enabled,
but otherwise leaves them alone.

```nix
{
  imports = [
    nix-bitcoin.nixosModules.default
    roost.nixosModules.public-frigate
  ];

  services.bitcoind = {
    enable  = true;
    txindex = true;
    dataDirReadableByGroup = true;
  };
  services.fulcrum.enable = true;

  services.public-frigate = {
    enable = true;
    host   = "frigate.example.com";
    tls.acmeEmail = "ops@example.com";
  };
}
```

## Bring your own TLS

Set `tls.certificateFile` and `tls.keyFile` instead of `tls.acmeEmail`
to use a certificate you manage out of band:

```nix
services.public-frigate = {
  enable = true;
  host   = "frigate.example.com";
  tls.certificateFile = "/var/lib/frigate-tls/fullchain.pem";
  tls.keyFile         = "/var/lib/frigate-tls/privkey.pem";
};
```

## Tests

```
nix flake check
```

runs two VM tests:

- `regtest-e2e` — the bare frigate module against nix-bitcoin's
  bitcoind and electrs. Mines 101 regtest blocks and verifies Frigate
  answers an Electrum-protocol query on its internal port. Kept on
  electrs to demonstrate the bare module is backend-agnostic.
- `regtest-preset` — `nixosModules.default` end-to-end with fulcrum
  as the Electrum backend. Same regtest scenario plus an
  Electrum-over-TLS probe through the preset's nginx termination
  using a self-signed certificate.

Downstream consumers can run either test against their own
configuration:

```nix
checks.x86_64-linux.frigate = roost.lib.mkRegtestPresetE2E {
  pkgs         = nixpkgs.legacyPackages.x86_64-linux;
  extraModules = [ ./my-host.nix ];
};
```

## Updating frigate

The pinned frigate tag lives in `pkgs/frigate/package.nix`. To bump it:

1. Find the new tag and its commit SHA at
   <https://github.com/sparrowwallet/frigate/tags>.
2. In `pkgs/frigate/package.nix`, update `version`, the `src.rev`, and the
   `# tag:` comment beside the rev. Set `src.hash` to the new tarball
   hash — either zero the field out and let `nix build` print the
   expected SRI, or prefetch it:

   ```
   nix-prefetch-url --unpack --type sha256 \
     https://github.com/sparrowwallet/frigate/archive/<rev>.tar.gz
   nix hash to-sri --type sha256 <printed-hash>
   ```
3. Check whether the drongo submodule pointer changed in the new tag
   (`git ls-tree <rev> drongo` on a frigate checkout, or inspect the
   release diff). If it did, update `drongoSrc.rev` and `drongoSrc.hash`
   the same way.
4. Build: `nix build .#frigate`. If gradle dependencies changed, the
   build will fail with a mismatch against `pkgs/frigate/deps.json`.
   Regenerate it by running the mitm-cache fetch script that nixpkgs's
   gradle infrastructure exposes — it rewrites `pkgs/frigate/deps.json`
   in place, so run it from the repo root:

   ```
   $(nix build .#frigate.mitmCache.updateScript --no-link --print-out-paths)
   ```

   Re-run `nix build .#frigate` to confirm.
5. Run the VM tests: `nix flake check`.
6. Sanity-check the version string: `./result/bin/frigate --version`.

## License

MIT. See [LICENSE](LICENSE).
