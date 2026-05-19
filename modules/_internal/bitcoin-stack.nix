{
  config,
  lib,
  pkgs,
  ...
}:

# Internal helper: bitcoind + fulcrum stack with optional mesh exposure.
# Shared between `public-frigate` (whose frigate process consumes the stack
# locally) and `bitcoind-backend` (which provides the same stack as a
# remote backend for edge consumers).
#
# Both presets wire `services._roost.bitcoin-stack.{enable, expose.*}`
# from their own typed options. Not part of the stable API.
#
# Why this exists: the configuration of bitcoind (txindex, listen, ZMQ
# sequence publisher, AF_NETLINK workaround for getifaddrs in libzmq)
# and fulcrum (the canonical Electrum backend), plus the optional
# expose-on-private-interface bits (extra rpcbind line, rpcauth user,
# fulcrum tcp= line, interface-scoped firewall), are identical whether
# the consumer is colocated frigate or a remote frigate-edge.

let
  cfg = config.services._roost.bitcoin-stack;

  # Frigate occupies the canonical Electrum ports (50001 plaintext,
  # 50002 TLS) when it is the consumer; fulcrum moves off 50001 to
  # this non-conflicting port. The README example uses 60001. Captured
  # in one place so consumer presets and this stack don't drift.
  backendPort = 60001;

  # bitcoind opens its ZMQ sequence socket here. With no edge
  # consumers, bind to loopback only. With `expose.enable`, bind to
  # 0.0.0.0 so both local frigate (via 127.0.0.1) and remote edge
  # frigate (via `bindAddress`) can subscribe; the firewall scopes
  # outside access to `expose.interface` only.
  zmqPublishBind = if cfg.expose.enable then "0.0.0.0" else "127.0.0.1";
in
{
  options.services._roost.bitcoin-stack = with lib; {
    enable = mkOption {
      type = types.bool;
      default = false;
      internal = true;
      description = "Enable shared bitcoind+fulcrum stack. Set by a parent preset, not by hand.";
    };

    dbCache = mkOption {
      type = types.int;
      default = 4096;
      internal = true;
      description = "bitcoind UTXO cache in MB. Parent preset may override.";
    };

    expose = {
      enable = mkOption {
        type = types.bool;
        default = false;
        internal = true;
      };
      bindAddress = mkOption {
        type = types.str;
        default = "";
        internal = true;
      };
      interface = mkOption {
        type = types.str;
        default = "";
        internal = true;
      };
      allowedPeers = mkOption {
        type = types.listOf types.str;
        default = [ ];
        internal = true;
      };
      rpcAuth = {
        user = mkOption {
          type = types.str;
          default = "";
          internal = true;
        };
        passwordHMAC = mkOption {
          type = types.str;
          default = "";
          internal = true;
        };
      };
    };

    # Re-export `backendPort` so parent presets can reference the
    # fulcrum listen port without duplicating the constant. Read-only
    # by convention; presets don't override.
    backendPort = mkOption {
      type = types.port;
      default = backendPort;
      internal = true;
      readOnly = true;
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # nix-bitcoin requires a secrets policy whenever bitcoind is
        # enabled through it. Default to its built-in generator, which
        # writes RPC credentials to /etc/nix-bitcoin-secrets (mode 0400)
        # on activation. Override to "manual" if secrets are managed out
        # of band (agenix etc.).
        nix-bitcoin.generateSecrets = lib.mkDefault true;

        services.bitcoind = {
          enable = true;
          txindex = true;
          listen = true;
          address = "0.0.0.0";
          dataDirReadableByGroup = true;
          dbCache = lib.mkDefault cfg.dbCache;
        };

        services.fulcrum = {
          enable = true;
          port = lib.mkDefault backendPort;
        };

        # bitcoind p2p port is always public — that's how the node finds
        # peers and stays at tip.
        networking.firewall.allowedTCPPorts = [ 8333 ];

        # ZMQ sequence publisher. The endpoint switches between loopback
        # and 0.0.0.0 depending on whether the stack is exposing to edge
        # consumers; the firewall scopes any external access to the
        # configured interface.
        #
        # nix-bitcoin's bitcoind module loosens RestrictAddressFamilies
        # to include AF_NETLINK only when its *typed* ZMQ options
        # (`zmqpubrawblock`, `zmqpubrawtx`) are set — see
        # `zmqServerEnabled` in modules/bitcoind.nix and `allowNetlink`
        # in pkgs/lib.nix on the locked release. Going through
        # `extraConfig` bypasses that gate, so libzmq's `getifaddrs()`
        # call during `zmq_bind` hits EAFNOSUPPORT and `resolve_nic_name`
        # aborts the daemon. Mirror `allowNetlink` here:
        # `AF_UNIX AF_INET AF_INET6` is the verbatim
        # `defaultHardening.RestrictAddressFamilies` value, plus the
        # `AF_NETLINK` `allowNetlink` would have added. mkForce because
        # the nix-bitcoin module already assigns the string.
        services.bitcoind.extraConfig = ''
          zmqpubsequence=tcp://${zmqPublishBind}:28336
        '';
        systemd.services.bitcoind.serviceConfig.RestrictAddressFamilies =
          lib.mkForce "AF_UNIX AF_INET AF_INET6 AF_NETLINK";
      }

      # Expose path: bind bitcoind RPC + ZMQ + fulcrum on a mesh
      # interface for edge consumers.
      #
      # bitcoind RPC: nix-bitcoin's `rpc.address` is single-valued, so
      # keep the typed loopback default and append a second `rpcbind=`
      # via extraConfig. bitcoind accepts repeated rpcbind lines.
      #
      # ZMQ: already flips to 0.0.0.0 above when `expose.enable` is set.
      #
      # fulcrum: same single-bind pattern. Typed `address` stays on
      # loopback; an extra `tcp = ...` line is appended via `extraConfig`
      # for the mesh address.
      (lib.mkIf cfg.expose.enable {
        services.bitcoind = {
          rpc.allowip = [ "127.0.0.1" ] ++ cfg.expose.allowedPeers;
          rpc.users.${cfg.expose.rpcAuth.user} = {
            inherit (cfg.expose.rpcAuth) passwordHMAC;
          };
          extraConfig = ''
            rpcbind=${cfg.expose.bindAddress}
          '';
        };

        services.fulcrum.extraConfig = ''
          tcp = ${cfg.expose.bindAddress}:${toString backendPort}
        '';

        # Scope the open ports to the mesh interface only. Outside
        # traffic (e.g. the public internet on eth0) is dropped at
        # INPUT by NixOS's default-deny firewall posture.
        #
        # bitcoind's RPC port is pulled from config rather than
        # hardcoded — nix-bitcoin's `rpc.port` default tracks the chain
        # (8332 mainnet, 18443 regtest, 18332 testnet, etc.).
        networking.firewall.interfaces.${cfg.expose.interface}.allowedTCPPorts = [
          config.services.bitcoind.rpc.port
          28336
          backendPort
        ];
      })
    ]
  );
}
