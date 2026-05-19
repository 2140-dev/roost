{
  config,
  lib,
  ...
}:

# Backend-only preset: bitcoind + fulcrum + ZMQ sequence publisher,
# exposed on a private interface for one or more edge consumers (a
# `frigate-edge` somewhere else). No frigate process here, no TLS, no
# ACME — this box's job is to be the Bitcoin Core RPC + Electrum
# backend reachable over a mesh.
#
# Pairs with `frigate-edge` on consumer hosts. The two halves wire up
# via `roost.nixosModules.wireguard-mesh` (or any other private
# transport — `bitcoind-backend` is transport-neutral; it just binds
# its services on a configured address and scopes the firewall to a
# configured interface).
#
# This preset and `public-frigate` share the bitcoind/fulcrum
# implementation via the private `_internal/bitcoin-stack.nix`
# helper. Differences:
#
#   - `public-frigate` adds frigate + TLS + ACME on top of the stack
#     (one box does everything).
#   - `bitcoind-backend` is just the stack with exposure always on
#     (one box hosts the backends for another box's frigate-edge).
#
# Bitcoin implementation: the underlying `services.bitcoind` is from
# nix-bitcoin. To swap to a Bitcoin Core fork (Knots, etc.), set
# `services.bitcoind.package` in the consumer's host config — the
# RPC/ZMQ contract is identical. For a non-Core implementation that
# speaks Bitcoin Core RPC + ZMQ sequence (e.g. btcd), this preset
# would need a sibling preset that provides the same exposed
# interface via different internals.

let
  cfg = config.services.bitcoind-backend;
in
{
  imports = [
    ../_internal/bitcoin-stack.nix
  ];

  options.services.bitcoind-backend = with lib; {
    enable = mkEnableOption "Bitcoin Core RPC + Electrum backend exposed on a private interface";

    network = mkOption {
      type = types.enum [
        "mainnet"
        "testnet"
        "testnet4"
        "signet"
        "regtest"
      ];
      default = "mainnet";
      description = ''
        Chain this bitcoind serves. The exposed RPC port follows
        nix-bitcoin's per-chain defaults (8332 mainnet, 18443 regtest,
        18332 testnet, 38332 signet). Consumers reaching this backend
        need to use the matching port for the chain in their
        `frigate-edge.backend.bitcoind.rpcUrl`.
      '';
    };

    dbCache = mkOption {
      type = types.int;
      default = 4096;
      description = ''
        bitcoind UTXO cache size in MB. Default 4 GB — fine for a
        steady-state node. Raise this transiently during initial sync
        if RAM is plentiful (the cost is initial bring-up time, not
        steady-state memory).
      '';
    };

    bindAddress = mkOption {
      type = types.str;
      example = "10.42.0.3";
      description = ''
        Private-network address bitcoind RPC, ZMQ sequence, and
        fulcrum bind to (in addition to their loopback defaults).
        Typically this host's mesh IP. The interface this address sits
        on must match `interface` below — that's where firewall rules
        are scoped.
      '';
    };

    interface = mkOption {
      type = types.str;
      example = "wg0";
      description = ''
        Name of the interface used to scope firewall rules. Only
        traffic arriving on this interface is allowed to reach the
        backend ports; nothing on eth0 (the public interface) can
        reach them.
      '';
    };

    allowedPeers = mkOption {
      type = types.listOf types.str;
      example = [
        "10.42.0.1/32"
        "10.42.0.2/32"
      ];
      description = ''
        Source CIDRs added to bitcoind's `rpcallowip`. Must include
        every edge consumer's mesh IP (/32) that needs to talk to the
        backends. Loopback is always allowed.
      '';
    };

    rpcAuth = {
      user = mkOption {
        type = types.str;
        example = "frigate-edge";
        description = "RPC user name added to bitcoind for edge consumers.";
      };

      passwordHMAC = mkOption {
        type = types.str;
        example = "f7efda5c189b999524f151318c0c86$d5b51b3beffbc02b724e5d095828e0bc8b2456e9ac8757ae3211a5d9b16a22ae";
        description = ''
          Literal `salt$hash` portion of an rpcauth line, as produced
          by bitcoind's `rpcauth.py`. Committed to nix config — the
          HMAC is one-way derived from the password; only the
          corresponding plaintext is a secret (lives on the edge
          consumer).
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services._roost.bitcoin-stack = {
      enable = true;
      dbCache = cfg.dbCache;
      expose = {
        enable = true;
        bindAddress = cfg.bindAddress;
        interface = cfg.interface;
        allowedPeers = cfg.allowedPeers;
        rpcAuth = {
          inherit (cfg.rpcAuth) user passwordHMAC;
        };
      };
    };
  };
}
