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

    electrs.manage = mkOption {
      type = types.bool;
      default = false;
      description = ''
        When true, the preset enables `services.electrs`. When false
        (default), the preset asserts electrs is enabled and leaves it
        alone.
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
            assertion = cfg.electrs.manage || (config.services ? electrs && config.services.electrs.enable);
            message = ''
              services.public-frigate requires services.electrs.enable = true.
              Either import an electrs module and enable it, or set
              services.public-frigate.electrs.manage = true.
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

      (lib.mkIf cfg.electrs.manage {
        services.electrs.enable = true;
      })

      {
        services.frigate = {
          enable = true;
          host = cfg.host;
          network = cfg.network;
          bitcoind = {
            enable = true;
            server = "http://127.0.0.1:8332";
            authType = "COOKIE";
            cookieDir = "/var/lib/bitcoind";
          };
          electrumBackend = "tcp://127.0.0.1:50001";
        };

        users.users.frigate.extraGroups = [ "bitcoin" ];

        systemd.services.frigate.after = [
          "bitcoind.service"
          "electrs.service"
        ];
        systemd.services.frigate.wants = [
          "bitcoind.service"
          "electrs.service"
        ];
      }

      # nginx terminates TLS and stream-proxies to frigate. Electrum is raw
      # TCP+TLS, not HTTP, so the listener belongs in the `stream` context.
      {
        services.nginx = {
          enable = true;
          streamConfig = ''
            server {
              listen ${toString cfg.publicPort} ssl;
              ssl_certificate     ${certFile};
              ssl_certificate_key ${keyFile};
              proxy_pass 127.0.0.1:${toString config.services.frigate.tcpPort};
            }
          '';
        };
        networking.firewall.allowedTCPPorts = [ cfg.publicPort ];
      }

      # ACME path: a minimal HTTP vhost on port 80 hosts the HTTP-01
      # challenge so Let's Encrypt can verify domain ownership. NixOS's
      # `enableACME` wires `security.acme.certs.<host>` and the challenge
      # location automatically; the `404` covers anything else hitting
      # this vhost.
      (lib.mkIf (cfg.tls.acmeEmail != null) {
        security.acme = {
          acceptTerms = true;
          defaults.email = cfg.tls.acmeEmail;
        };

        services.nginx.virtualHosts.${cfg.host} = {
          enableACME = true;
          locations."/".return = "404";
        };

        networking.firewall.allowedTCPPorts = [ 80 ];

        # nginx reads cert files from /var/lib/acme; the acme group owns
        # them.
        users.users.nginx.extraGroups = [ "acme" ];
      })
    ]
  );
}
