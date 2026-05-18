{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.public-frigate;

  # When ACME issues the cert, nginx writes it to `/var/lib/acme/<host>/`.
  # When the consumer brings their own, we point straight at their files.
  certFile =
    if cfg.tls.certificateFile != null then
      cfg.tls.certificateFile
    else
      "/var/lib/acme/${cfg.host}/fullchain.pem";
  keyFile = if cfg.tls.keyFile != null then cfg.tls.keyFile else "/var/lib/acme/${cfg.host}/key.pem";
in
{
  imports = [ ../frigate.nix ];

  options.services.public-frigate = with lib; {
    enable = mkEnableOption "public-facing Frigate silent payments server";

    host = mkOption {
      type = types.str;
      example = "frigate.example.com";
      description = ''
        Public DNS name for this server. Advertised in the Electrum
        `server.features` response and used as the nginx server_name for
        TLS termination.
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
            assertion =
              (cfg.tls.acmeEmail == null) || (cfg.tls.certificateFile == null && cfg.tls.keyFile == null);
            message = ''
              services.public-frigate.tls.acmeEmail is mutually exclusive with
              tls.certificateFile / tls.keyFile.
            '';
          }
          {
            assertion =
              (cfg.tls.acmeEmail != null) || (cfg.tls.certificateFile != null && cfg.tls.keyFile != null);
            message = ''
              services.public-frigate requires either tls.acmeEmail (for ACME)
              or both tls.certificateFile and tls.keyFile (for a manual cert).
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
        services.frigate = {
          enable = true;
          host = cfg.host;
          network = cfg.network;
          tcp = "tcp://127.0.0.1:50001";
          ssl = "ssl://0.0.0.0:${toString cfg.publicPort}";
          sslCert = certFile;
          sslKey = keyFile;
          bitcoind = {
            enable = true;
            server = "http://127.0.0.1:8332";
            authType = "COOKIE";
            cookieDir = "/var/lib/bitcoind";
            zmqSequenceEndpoint = "tcp://127.0.0.1:28336";
          };
          electrumBackend = "tcp://127.0.0.1:60001";
          # ACME-issued certs live in /var/lib/acme/<host>/ owned by the
          # `acme` group. Frigate reads them at startup, so its service
          # needs the group. Skipped for manual-cert deployments where
          # the operator has already arranged read access.
          extraSupplementaryGroups = lib.optional (cfg.tls.acmeEmail != null) "acme";
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

        # Frigate now occupies the canonical Electrum ports (50001/50002).
        # Move the local backend off 50001 so the two don't collide. The
        # value mirrors `services.frigate.electrumBackend` above; keep
        # them in sync if you change it. mkDefault so a consumer running
        # their own fulcrum out of band can still override.
        services.fulcrum.port = lib.mkDefault 60001;

        networking.firewall.allowedTCPPorts = [ cfg.publicPort ];
      }

      # Pair bitcoind's ZMQ sequence publisher with frigate's
      # `zmqSequenceEndpoint`. Only wired here when the preset is
      # managing bitcoind — a consumer running bitcoind out of band must
      # add `zmqpubsequence=tcp://127.0.0.1:28336` themselves, or
      # mkForce `services.frigate.bitcoind.zmqSequenceEndpoint = null`
      # to fall back to polling (and accept the upstream warning).
      (lib.mkIf cfg.bitcoind.manage {
        services.bitcoind.extraConfig = ''
          zmqpubsequence=tcp://127.0.0.1:28336
        '';
      })

      # ACME path: a minimal HTTP vhost on port 80 hosts the HTTP-01
      # challenge so Let's Encrypt can verify domain ownership. NixOS's
      # `enableACME` wires `security.acme.certs.<host>` and the challenge
      # location automatically; the `404` covers anything else hitting
      # this vhost. nginx is only here for ACME — TLS termination for
      # the Electrum stream is frigate's job.
      (lib.mkIf (cfg.tls.acmeEmail != null) {
        security.acme = {
          acceptTerms = true;
          defaults.email = cfg.tls.acmeEmail;
        };

        services.nginx = {
          enable = true;
          virtualHosts.${cfg.host} = {
            enableACME = true;
            locations."/".return = "404";
          };
        };

        networking.firewall.allowedTCPPorts = [ 80 ];

        # Block frigate startup until the cert exists, otherwise it
        # crash-loops on `cert.pem: No such file or directory` during a
        # fresh deploy. `wants` (not `requires`) so a transient acme
        # failure later doesn't take frigate down with it. List values
        # under `systemd.services.<name>` accumulate via module merging,
        # so this composes with the bitcoind/fulcrum deps above.
        systemd.services.frigate.after = [ "acme-${cfg.host}.service" ];
        systemd.services.frigate.wants = [ "acme-${cfg.host}.service" ];
      })
    ]
  );
}
