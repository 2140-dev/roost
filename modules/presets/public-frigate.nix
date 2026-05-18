{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.public-frigate;

  # Frigate occupies the canonical Electrum ports (50001 plaintext,
  # `publicPort` for TLS); the backend Electrum server (fulcrum) moves
  # off 50001 to this non-conflicting port. The README example uses
  # 60001. Captured here so the fulcrum listen port and frigate's
  # `electrumBackend` URL can't drift apart.
  backendPort = 60001;

  # The local frigate process always reads ZMQ off loopback; that's a
  # constant. When `exposeBackends` is on, bitcoind additionally binds
  # the same socket on the mesh address so edge consumers can subscribe
  # — see the publish endpoint below.
  zmqSequenceEndpoint = "tcp://127.0.0.1:28336";

  # Where bitcoind opens the ZMQ socket. With no edge consumers, bind
  # to loopback only. With `exposeBackends.enable`, bind to 0.0.0.0 so
  # both local frigate (via 127.0.0.1) and remote edge frigate (via
  # `bindAddress`) can subscribe; the firewall scopes outside access
  # to `exposeBackends.interface` only.
  zmqPublishBind = if cfg.exposeBackends.enable then "0.0.0.0" else "127.0.0.1";
  zmqPublishEndpoint = "tcp://${zmqPublishBind}:28336";
in
{
  imports = [
    ../frigate.nix
    ../_internal/frigate-tls-acme.nix
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
        ];
      }

      (lib.mkIf cfg.bitcoind.manage {
        # nix-bitcoin requires a secrets policy whenever bitcoind is enabled
        # through it. Default to its built-in generator, which writes RPC
        # credentials to /etc/nix-bitcoin-secrets (mode 0400) on activation.
        # Override to "manual" if you manage secrets out of band (agenix etc.).
        nix-bitcoin.generateSecrets = lib.mkDefault true;

        services.bitcoind = {
          enable = true;
          txindex = true;
          listen = true;
          address = "0.0.0.0";
          dataDirReadableByGroup = true;
          dbCache = lib.mkDefault 4096;
        };
        networking.firewall.allowedTCPPorts = [ 8333 ];
      })

      (lib.mkIf cfg.fulcrum.manage {
        services.fulcrum.enable = true;
      })

      {
        # Frigate terminates TLS itself on the public port. The plaintext
        # listener is bound to loopback for local probes/operator use —
        # all public traffic comes in over `ssl`. The backend Electrum
        # server (fulcrum/electrs/etc.) listens on a non-conflicting port
        # so frigate can occupy the canonical Electrum ports.
        #
        # `sslCert`, `sslKey` and `extraSupplementaryGroups` are set by
        # the shared TLS+ACME helper (imported above).
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
          electrumBackend = "tcp://127.0.0.1:${toString backendPort}";
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

        # Move fulcrum off 50001 so frigate can occupy the canonical
        # Electrum ports. mkDefault so a consumer running their own
        # fulcrum out of band can still override.
        services.fulcrum.port = lib.mkDefault backendPort;

        networking.firewall.allowedTCPPorts = [ cfg.publicPort ];
      }

      # Pair bitcoind's ZMQ sequence publisher with frigate's
      # `zmqSequenceEndpoint`. Only wired here when the preset is
      # managing bitcoind — a consumer running bitcoind out of band must
      # add `zmqpubsequence=...` (matching the endpoint above)
      # themselves, or mkForce
      # `services.frigate.bitcoind.zmqSequenceEndpoint = null` to fall
      # back to polling (and accept the upstream warning).
      #
      # nix-bitcoin's bitcoind module loosens RestrictAddressFamilies to
      # include AF_NETLINK only when its *typed* ZMQ options
      # (`zmqpubrawblock`, `zmqpubrawtx`) are set — see `zmqServerEnabled`
      # in modules/bitcoind.nix and `allowNetlink` in pkgs/lib.nix on
      # the locked release. Going through `extraConfig` bypasses that
      # gate, so libzmq's `getifaddrs()` call during `zmq_bind` hits
      # EAFNOSUPPORT and `resolve_nic_name` aborts the daemon. Mirror
      # `allowNetlink` here: `AF_UNIX AF_INET AF_INET6` is the verbatim
      # `defaultHardening.RestrictAddressFamilies` value, plus the
      # `AF_NETLINK` `allowNetlink` would have added. mkForce because
      # the nix-bitcoin module already assigns the string.
      (lib.mkIf cfg.bitcoind.manage {
        services.bitcoind.extraConfig = ''
          zmqpubsequence=${zmqPublishEndpoint}
        '';
        systemd.services.bitcoind.serviceConfig.RestrictAddressFamilies =
          lib.mkForce "AF_UNIX AF_INET AF_INET6 AF_NETLINK";
      })

      # exposeBackends: bind bitcoind RPC + ZMQ + fulcrum on the mesh
      # interface for an edge consumer. Only honored when the preset is
      # managing those services locally — exposing services we don't
      # manage would be a contract violation.
      #
      # bitcoind RPC: nix-bitcoin's `rpc.address` is single-valued, so
      # we keep the typed loopback default and append a second
      # `rpcbind=` via extraConfig. bitcoind accepts repeated rpcbind
      # lines and binds each one.
      #
      # ZMQ: the publish endpoint above (`zmqPublishEndpoint`) already
      # flips to 0.0.0.0 when exposeBackends is on — no extraConfig
      # work needed here for ZMQ.
      #
      # fulcrum: same single-bind option pattern as bitcoind RPC. The
      # typed `address` stays on loopback; an extra `tcp = ...` line is
      # appended via `extraConfig` for the mesh address.
      (lib.mkIf cfg.exposeBackends.enable {
        assertions = [
          {
            assertion = cfg.bitcoind.manage;
            message = ''
              services.public-frigate.exposeBackends.enable requires
              services.public-frigate.bitcoind.manage = true. The preset
              cannot expose a bitcoind it does not configure.
            '';
          }
          {
            assertion = cfg.fulcrum.manage;
            message = ''
              services.public-frigate.exposeBackends.enable requires
              services.public-frigate.fulcrum.manage = true. The preset
              cannot expose a fulcrum it does not configure.
            '';
          }
        ];

        services.bitcoind = {
          rpc.allowip = [ "127.0.0.1" ] ++ cfg.exposeBackends.allowedPeers;
          rpc.users.${cfg.exposeBackends.rpcAuth.user} = {
            inherit (cfg.exposeBackends.rpcAuth) passwordHMAC;
          };
          extraConfig = ''
            rpcbind=${cfg.exposeBackends.bindAddress}
          '';
        };

        services.fulcrum.extraConfig = ''
          tcp = ${cfg.exposeBackends.bindAddress}:${toString backendPort}
        '';

        # Scope the open ports to the mesh interface only. Outside
        # traffic (e.g. the public internet on eth0) is dropped at
        # INPUT by NixOS's default-deny firewall posture.
        networking.firewall.interfaces.${cfg.exposeBackends.interface}.allowedTCPPorts = [
          8332
          28336
          backendPort
        ];
      })
    ]
  );
}
