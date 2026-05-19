{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.public-frigate;
  stack = config.services._roost.bitcoin-stack;

  # The local frigate process always reads ZMQ off loopback; that's a
  # constant. When `exposeBackends` is on, bitcoind additionally binds
  # the same socket on the mesh address so edge consumers can subscribe
  # (the bitcoin-stack helper handles the bind switch).
  zmqSequenceEndpoint = "tcp://127.0.0.1:28336";
in
{
  imports = [
    ../frigate.nix
    ../_internal/frigate-tls-acme.nix
    ../_internal/bitcoin-stack.nix
  ];

  options.services.public-frigate = with lib; {
    enable = mkEnableOption "public-facing Frigate silent payments server";

    host = mkOption {
      type = types.str;
      example = "frigate.example.com";
      description = ''
        Public DNS name for this server. Advertised in the Electrum
        `server.features` response, used as the SAN clients validate
        against the served TLS certificate, and — when `tls.acmeEmail`
        is set — as the `security.acme.certs.<name>` identifier.
      '';
    };

    network = mkOption {
      type = types.enum [
        "mainnet"
        "testnet"
        "testnet4"
        "signet"
        "regtest"
      ];
      default = "mainnet";
    };

    publicPort = mkOption {
      type = types.port;
      default = 50002;
      description = ''
        Public TLS port. 50002 is the convention for Electrum-over-SSL and
        the default Sparrow Wallet probes for.
      '';
    };

    tls = {
      acmeEmail = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "ops@example.com";
        description = ''
          Email address for Let's Encrypt registration. Setting it enables
          ACME for `host`. Mutually exclusive with manual cert/key files.
        '';
      };

      certificateFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to a TLS certificate. Required when not using ACME.";
      };

      keyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to the matching TLS private key. Required when not using ACME.";
      };
    };

    bitcoind.manage = mkOption {
      type = types.bool;
      default = false;
      description = ''
        When true, the preset configures `services.bitcoind` for a public
        Frigate node: txindex, P2P listen, group-readable cookie, 4 GB
        UTXO cache. Requires a bitcoind NixOS module to already be in the
        consumer's imports — typically `nix-bitcoin.nixosModules.default`.
        When false (default), the preset asserts that bitcoind is enabled
        and txindex is on, and otherwise leaves it alone.
      '';
    };

    fulcrum.manage = mkOption {
      type = types.bool;
      default = false;
      description = ''
        When true, the preset enables `services.fulcrum` (nix-bitcoin's
        module). When false (default), the preset asserts fulcrum is
        enabled and leaves it alone.
      '';
    };

    exposeBackends = {
      enable = mkEnableOption "expose bitcoind RPC/ZMQ and fulcrum for edge consumers";

      bindAddress = mkOption {
        type = types.str;
        example = "10.42.0.1";
        description = ''
          Additional address bitcoind RPC, ZMQ sequence, and fulcrum
          bind to (in addition to their loopback defaults). Typically
          this host's mesh IP — see `roost.nixosModules.wireguard-mesh`.
        '';
      };

      interface = mkOption {
        type = types.str;
        example = "wg0";
        description = ''
          Interface name used to scope the firewall rules that open the
          backend ports. Only traffic arriving on this interface is
          accepted; the backends remain unreachable from the public
          internet.
        '';
      };

      allowedPeers = mkOption {
        type = types.listOf types.str;
        example = [ "10.42.0.2/32" ];
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

    # Sentinel attribute, mirroring nix-bitcoin's `secure-node-preset-enabled`.
    # Lets downstream modules and tests detect activation without re-checking
    # every individual service.
    preset-enabled = mkOption {
      type = types.attrs;
      default = { };
      internal = true;
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      { services.public-frigate.preset-enabled = { }; }

      # TLS + ACME wiring is shared with frigate-edge; delegate to the
      # private helper module. TLS-mutex assertions live there too.
      {
        services._roost.frigate-tls-acme = {
          enable = true;
          inherit (cfg) host tls;
        };
      }

      # bitcoind + fulcrum (+ optional mesh exposure) are shared with
      # `bitcoind-backend`; delegate to the private helper module.
      # Only activate the helper when this preset is the one managing
      # the services locally — the `manage = false` path lets a
      # consumer wire bitcoind/fulcrum out of band and just have
      # frigate point at them.
      (lib.mkIf (cfg.bitcoind.manage && cfg.fulcrum.manage) {
        services._roost.bitcoin-stack = {
          enable = true;
          expose = {
            enable = cfg.exposeBackends.enable;
            bindAddress = cfg.exposeBackends.bindAddress;
            interface = cfg.exposeBackends.interface;
            allowedPeers = cfg.exposeBackends.allowedPeers;
            rpcAuth = {
              inherit (cfg.exposeBackends.rpcAuth) user passwordHMAC;
            };
          };
        };
      })

      {
        assertions = [
          {
            assertion = cfg.bitcoind.manage || (config.services ? bitcoind && config.services.bitcoind.enable);
            message = ''
              services.public-frigate requires services.bitcoind.enable = true.
              Either import a bitcoind module (e.g. nix-bitcoin.nixosModules.default)
              and enable it, or set services.public-frigate.bitcoind.manage = true.
            '';
          }
          {
            assertion =
              cfg.bitcoind.manage || !(config.services ? bitcoind) || config.services.bitcoind.txindex;
            message = "services.public-frigate requires services.bitcoind.txindex = true.";
          }
          {
            assertion = cfg.fulcrum.manage || (config.services ? fulcrum && config.services.fulcrum.enable);
            message = ''
              services.public-frigate requires services.fulcrum.enable = true.
              Either import nix-bitcoin (which provides the fulcrum module)
              and enable it, or set services.public-frigate.fulcrum.manage = true.
            '';
          }
          {
            assertion = !cfg.exposeBackends.enable || (cfg.bitcoind.manage && cfg.fulcrum.manage);
            message = ''
              services.public-frigate.exposeBackends.enable requires both
              bitcoind.manage = true and fulcrum.manage = true. The preset
              cannot expose services it does not configure.
            '';
          }
        ];
      }

      {
        # Frigate terminates TLS itself on the public port. The plaintext
        # listener is bound to loopback for local probes/operator use —
        # all public traffic comes in over `ssl`. The backend Electrum
        # server (fulcrum) listens on `bitcoin-stack`'s `backendPort` so
        # frigate can occupy the canonical Electrum ports.
        #
        # `sslCert`, `sslKey` and `extraSupplementaryGroups` are set by
        # the shared TLS+ACME helper.
        services.frigate = {
          enable = true;
          host = cfg.host;
          network = cfg.network;
          tcp = "tcp://127.0.0.1:50001";
          ssl = "ssl://0.0.0.0:${toString cfg.publicPort}";
          bitcoind = {
            enable = true;
            server = "http://127.0.0.1:8332";
            authType = "COOKIE";
            cookieDir = "/var/lib/bitcoind";
            inherit zmqSequenceEndpoint;
          };
          electrumBackend = "tcp://127.0.0.1:${toString stack.backendPort}";
        };

        users.users.frigate.extraGroups = [ "bitcoin" ];

        systemd.services.frigate.after = [
          "bitcoind.service"
          "fulcrum.service"
        ];
        systemd.services.frigate.wants = [
          "bitcoind.service"
          "fulcrum.service"
        ];

        networking.firewall.allowedTCPPorts = [ cfg.publicPort ];
      }
    ]
  );
}
