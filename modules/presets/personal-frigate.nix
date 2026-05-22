{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.personal-frigate;
in
{
  imports = [
    ../frigate.nix
  ];

  options.services.personal-frigate = with lib; {
    enable = mkEnableOption "personal Frigate (single-box, plaintext, electrs backend)";

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
        Chain Frigate scans. Propagated to services.frigate.network and
        services.bitcoind.<chain> when `bitcoind.manage = true`.
      '';
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "10.0.0.5";
      description = ''
        Single address Frigate's plaintext Electrum listener binds to.
        Default 127.0.0.1 is correct for a Sparrow wallet running on the
        same box. Set to a LAN/VPN IP to let another machine (e.g. a
        laptop running Sparrow) connect; in that case you must also open
        `port` in your own `networking.firewall` config — this preset
        does not touch the firewall for non-loopback binds. Prefer a
        private transport (WireGuard / Tailscale) for that case since
        v1 has no TLS.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 50001;
      description = ''
        Plaintext Electrum port. 50001 is the convention Sparrow probes
        for. Frigate occupies it; the electrs backend is moved to
        `backendPort` (60001 by default) to avoid the conflict.
      '';
    };

    backendPort = mkOption {
      type = types.port;
      default = 60001;
      description = ''
        Loopback port electrs listens on; Frigate proxies non-silent-
        payments queries here. Kept off the canonical 50001 so Frigate
        can occupy that port. Loopback-only — never reachable from
        outside this host regardless of `listenAddress`.
      '';
    };

    host = mkOption {
      type = types.str;
      default = "localhost";
      description = ''
        Hostname advertised in Electrum `server.features`. Cosmetic for
        a personal deployment — Sparrow displays it but does not validate
        against it (no TLS in v1). Override if you want the wallet UI to
        show something other than `localhost`.
      '';
    };

    bitcoind.manage = mkOption {
      type = types.bool;
      default = false;
      description = ''
        When true, the preset configures `services.bitcoind`: txindex,
        loopback-only P2P, group-readable cookie, ZMQ sequence publisher
        on loopback. Requires a bitcoind NixOS module already imported —
        typically nix-bitcoin via `nixosModules.personal-frigate-host`.
        When false (default), the preset asserts bitcoind is enabled +
        txindex is on, and otherwise leaves it alone.
      '';
    };

    electrs.manage = mkOption {
      type = types.bool;
      default = false;
      description = ''
        When true, the preset enables nix-bitcoin's `services.electrs`
        on `backendPort` (loopback). Frigate consumes it as
        `electrumBackend`. When false (default), the preset asserts
        electrs is enabled and leaves it alone (the preset still wires
        frigate to `127.0.0.1:<backendPort>` — point your own electrs
        there or override services.frigate.electrumBackend in the host
        config).
      '';
    };

    dbCache = mkOption {
      type = types.int;
      default = 1024;
      description = ''
        bitcoind UTXO cache in MB. Only used when `bitcoind.manage = true`.
        1 GB suits a personal user on a NAS / small VPS / desktop; raise
        it transiently during initial sync if RAM is plentiful.
      '';
    };

    preset-enabled = mkOption {
      type = types.attrs;
      default = { };
      internal = true;
      description = "Sentinel mirroring nix-bitcoin convention; lets downstream detect activation.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    { services.personal-frigate.preset-enabled = { }; }

    {
      assertions = [
        {
          assertion = cfg.bitcoind.manage || (config.services ? bitcoind && config.services.bitcoind.enable);
          message = ''
            services.personal-frigate requires services.bitcoind.enable = true.
            Either import nix-bitcoin and enable it, or set
            services.personal-frigate.bitcoind.manage = true.
            For a batteries-included setup, import
            roost.nixosModules.personal-frigate-host.
          '';
        }
        {
          assertion =
            cfg.bitcoind.manage || !(config.services ? bitcoind) || config.services.bitcoind.txindex;
          message = "services.personal-frigate requires services.bitcoind.txindex = true.";
        }
        {
          assertion = cfg.electrs.manage || (config.services ? electrs && config.services.electrs.enable);
          message = ''
            services.personal-frigate requires services.electrs.enable = true.
            Either import nix-bitcoin and enable it, or set
            services.personal-frigate.electrs.manage = true.
          '';
        }
        {
          assertion = !cfg.electrs.manage || cfg.bitcoind.manage;
          message = ''
            services.personal-frigate.electrs.manage = true requires
            services.personal-frigate.bitcoind.manage = true. Either turn both
            on (typical: use nixosModules.personal-frigate-host) or turn both
            off and manage bitcoind + electrs out of band.
          '';
        }
        {
          assertion = cfg.port != cfg.backendPort;
          message = ''
            services.personal-frigate.port and .backendPort must differ
            (frigate listens on `port`, electrs on `backendPort`).
          '';
        }
      ];
    }

    {
      services.frigate = {
        enable = true;
        host = cfg.host;
        network = cfg.network;
        tcp = "tcp://${cfg.listenAddress}:${toString cfg.port}";
        ssl = null;
        bitcoind = {
          enable = true;
          # Hardcoded mainnet RPC port — regtest tests use mkForce to override.
          server = "http://127.0.0.1:8332";
          authType = "COOKIE";
          cookieDir = "/var/lib/bitcoind";
          zmqSequenceEndpoint = "tcp://127.0.0.1:28336";
        };
        electrumBackend = "tcp://127.0.0.1:${toString cfg.backendPort}";
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

    (lib.mkIf cfg.bitcoind.manage {
      nix-bitcoin.generateSecrets = lib.mkDefault true;

      services.bitcoind = {
        enable = true;
        txindex = true;
        listen = false;
        address = "127.0.0.1";
        dataDirReadableByGroup = true;
        dbCache = lib.mkDefault cfg.dbCache;
        extraConfig = ''
          zmqpubsequence=tcp://127.0.0.1:28336
        '';
      };

      # libzmq's `getifaddrs()` during `zmq_bind` needs AF_NETLINK, but
      # nix-bitcoin's bitcoind module only widens RestrictAddressFamilies
      # for its *typed* ZMQ options (`zmqpubrawblock`, `zmqpubrawtx`).
      # Configuring `zmqpubsequence` via extraConfig bypasses that gate,
      # so the daemon would abort on bind without this override. Same
      # rationale as in _internal/bitcoin-stack.nix.
      systemd.services.bitcoind.serviceConfig.RestrictAddressFamilies =
        lib.mkForce "AF_UNIX AF_INET AF_INET6 AF_NETLINK";
    })

    (lib.mkIf cfg.electrs.manage {
      services.electrs = {
        enable = true;
        address = "127.0.0.1";
        port = cfg.backendPort;
      };
    })
  ]);
}
