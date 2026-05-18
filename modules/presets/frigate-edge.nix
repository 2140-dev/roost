{
  config,
  lib,
  ...
}:

# Edge-mode Frigate: TLS + ACME + frigate, with bitcoind and fulcrum
# living on another host. The consumer points `backend.bitcoind.rpcUrl`,
# `backend.bitcoind.zmqSequenceEndpoint`, and `backend.electrumUrl` at
# the remote endpoints — typically over a private WireGuard mesh (see
# `roost.nixosModules.wireguard-mesh`) — and supplies a credentials
# file containing `user:password` for the bitcoind RPC.
#
# This preset is intentionally narrow: no nix-bitcoin, no local
# services.bitcoind or services.fulcrum, no `manage` flags. If you want
# everything on one box, use `public-frigate` (or `nixosModules.default`)
# instead.

let
  cfg = config.services.frigate-edge;
in
{
  imports = [
    ../frigate.nix
    ../_internal/frigate-tls-acme.nix
  ];

  options.services.frigate-edge = with lib; {
    enable = mkEnableOption "edge-mode public Frigate (TLS + ACME, backends on another host)";

    host = mkOption {
      type = types.str;
      example = "albatross.example.com";
      description = ''
        Public DNS name for this frigate node. Advertised in the Electrum
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
        Public TLS port. 50002 is the convention for Electrum-over-SSL.
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
        description = "Path to the matching PKCS#8 TLS private key. Required when not using ACME.";
      };
    };

    backend = {
      bitcoind = {
        rpcUrl = mkOption {
          type = types.str;
          example = "http://10.42.0.1:8332";
          description = ''
            URL of the bitcoind JSON-RPC endpoint on the backend host.
            Plain `http://` is fine when the transport is a private
            mesh; do not expose the backend RPC to the public internet.
          '';
        };

        authCredentialFile = mkOption {
          type = types.path;
          description = ''
            File on disk containing literally `user:password` for the
            bitcoind RPC user. Loaded via systemd `LoadCredential` and
            substituted into frigate's config.toml at service start;
            never read by the frigate process directly. Typically an
            agenix-decrypted path under `/run/agenix/`.

            The corresponding rpcauth line (`user:salt$hash`) lives on
            the backend host's bitcoin.conf. Generate the pair once via
            bitcoind's `rpcauth.py`.
          '';
        };

        zmqSequenceEndpoint = mkOption {
          type = types.str;
          example = "tcp://10.42.0.1:28336";
          description = ''
            URL of the bitcoind ZMQ `sequence` publisher on the backend
            host. Frigate subscribes for sub-100ms mempool ingestion.
          '';
        };
      };

      electrumUrl = mkOption {
        type = types.str;
        example = "tcp://10.42.0.1:60001";
        description = ''
          URL of the backing Electrum server (fulcrum) on the backend
          host. Frigate proxies non-silent-payments queries here.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # TLS + ACME wiring is shared with public-frigate; delegate to the
    # private helper module. TLS-mutex assertions live there.
    services._roost.frigate-tls-acme = {
      enable = true;
      inherit (cfg) host tls;
    };

    services.frigate = {
      enable = true;
      host = cfg.host;
      network = cfg.network;
      # Plaintext listener stays on loopback. All public traffic
      # arrives via the TLS listener below.
      tcp = "tcp://127.0.0.1:50001";
      ssl = "ssl://0.0.0.0:${toString cfg.publicPort}";
      bitcoind = {
        enable = true;
        server = cfg.backend.bitcoind.rpcUrl;
        authType = "USERPASS";
        authCredentialFile = cfg.backend.bitcoind.authCredentialFile;
        zmqSequenceEndpoint = cfg.backend.bitcoind.zmqSequenceEndpoint;
      };
      electrumBackend = cfg.backend.electrumUrl;
    };

    networking.firewall.allowedTCPPorts = [ cfg.publicPort ];
  };
}
