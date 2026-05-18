{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.frigate;
  tomlFormat = pkgs.formats.toml { };

  networkSubdir =
    {
      mainnet = "";
      testnet = "testnet";
      testnet4 = "testnet4";
      signet = "signet";
      regtest = "regtest";
    }
    .${cfg.network};

  configDir = if networkSubdir == "" then cfg.dataDir else "${cfg.dataDir}/${networkSubdir}";

  coreSettings = {
    connect = cfg.bitcoind.enable;
  }
  // lib.optionalAttrs cfg.bitcoind.enable {
    server = cfg.bitcoind.server;
    authType = cfg.bitcoind.authType;
  }
  // lib.optionalAttrs (cfg.bitcoind.authType == "COOKIE" && cfg.bitcoind.cookieDir != null) {
    dataDir = cfg.bitcoind.cookieDir;
  }
  // lib.optionalAttrs (cfg.bitcoind.authType == "USERPASS") {
    auth = "@FRIGATE_BITCOIND_AUTH@";
  }
  // lib.optionalAttrs (cfg.bitcoind.zmqSequenceEndpoint != null) {
    zmqSequenceEndpoint = cfg.bitcoind.zmqSequenceEndpoint;
  };

  serverSettings = {
    host = cfg.host;
    backendElectrumServer = cfg.electrumBackend;
  }
  // lib.optionalAttrs (cfg.tcp != null && cfg.tcp != "") {
    tcp = cfg.tcp;
  }
  // lib.optionalAttrs (cfg.ssl != null) {
    ssl = cfg.ssl;
    sslCert = toString cfg.sslCert;
    sslKey = toString cfg.sslKey;
  };

  baseSettings = lib.recursiveUpdate {
    core = coreSettings;
    server = serverSettings;
    scan.computeBackend = cfg.computeBackend;
    database.url = "jdbc:duckdb:${configDir}/frigate.duckdb";
  } cfg.settings;

  # Extract the port number from a "scheme://host:port" listener URL.
  # Returns null for non-matching strings or for empty/null inputs, which
  # the firewall logic below treats as "no port to open".
  portFromUrl =
    url:
    if url == null || url == "" then
      null
    else
      let
        m = builtins.match "^(tcp|ssl)://[^:/?#]+:([0-9]+).*$" url;
      in
      if m == null then null else lib.toInt (builtins.elemAt m 1);

  tcpPortFromUrl = portFromUrl cfg.tcp;
  sslPortFromUrl = portFromUrl cfg.ssl;

  configTemplate = tomlFormat.generate "frigate-config.toml" baseSettings;
in
{
  # nixpkgs ships an unrelated `services.frigate` (the Python NVR camera
  # project). Disable it so the option namespace belongs to this module.
  # Done here so consumers don't have to repeat the workaround.
  disabledModules = [ "services/video/frigate.nix" ];

  options.services.frigate = with lib; {
    enable = mkEnableOption "Frigate silent payments scanning server";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../pkgs/frigate/package.nix { };
      defaultText = literalExpression "pkgs.callPackage \"\${roost}/pkgs/frigate/package.nix\" { }";
      description = "Frigate package to use.";
    };

    user = mkOption {
      type = types.str;
      default = "frigate";
    };

    group = mkOption {
      type = types.str;
      default = "frigate";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/frigate";
      description = ''
        Frigate home directory. Passed via `--dir`. The DuckDB database and
        config.toml live under this path (mainnet) or under `<dataDir>/<network>/`
        for non-mainnet networks.
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

    host = mkOption {
      type = types.str;
      default = "localhost";
      description = ''
        Hostname advertised in `server.features`. Set to a public hostname for
        public-facing deployments.
      '';
    };

    tcp = mkOption {
      type = types.nullOr types.str;
      default = "tcp://0.0.0.0:50001";
      example = "tcp://127.0.0.1:50001";
      description = ''
        Plaintext Electrum listener bind URL. Defaults to the canonical
        Electrum plaintext port on all interfaces, matching Frigate's
        upstream default — gate public exposure via the firewall, not by
        leaving this on a loopback bind.

        Set to `null` (or `""`) to disable the plaintext listener
        entirely, e.g. when only TLS is wanted.
      '';
    };

    ssl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "ssl://0.0.0.0:50002";
      description = ''
        TLS Electrum listener bind URL. When set, `sslCert` and `sslKey`
        must also be provided. Frigate negotiates TLS 1.2 and 1.3 only;
        TLS 1.0/1.1 and SSLv3 are unconditionally disabled.
      '';
    };

    sslCert = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        PEM certificate (single cert or fullchain). Required when `ssl`
        is set. The frigate service must be able to read this path —
        typically that means adding the file's group to
        `extraSupplementaryGroups` (e.g. `acme` for NixOS-managed certs).
      '';
    };

    sslKey = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        PKCS#8 PEM private key matching `sslCert`. Required when `ssl`
        is set.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open the firewall for the ports parsed out of `tcp` and `ssl`.
        Ports that cannot be parsed (e.g. unset listeners) are skipped.
      '';
    };

    electrumBackend = mkOption {
      type = types.str;
      default = "tcp://localhost:50001";
      description = "Backing Electrum server (electrs / fulcrum / etc.).";
    };

    computeBackend = mkOption {
      type = types.enum [
        "AUTO"
        "GPU"
        "CPU"
      ];
      default = "AUTO";
    };

    logLevel = mkOption {
      type = types.enum [
        "ERROR"
        "WARN"
        "INFO"
        "DEBUG"
        "TRACE"
      ];
      default = "INFO";
      description = ''
        Frigate log level. Passed to frigate via `--level`. DEBUG/TRACE are
        useful for diagnosing connection or scan issues but are noisy in
        steady-state operation.
      '';
    };

    bitcoind = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether frigate connects to Bitcoin Core (`[core] connect`).";
      };

      server = mkOption {
        type = types.str;
        default = "http://127.0.0.1:8332";
      };

      authType = mkOption {
        type = types.enum [
          "COOKIE"
          "USERPASS"
        ];
        default = "COOKIE";
      };

      cookieDir = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Bitcoin Core data directory containing `.cookie`. Used when
          `authType = "COOKIE"`. Frigate must be able to read this path —
          add it to `serviceConfig.BindReadOnlyPaths` or run frigate as a
          user that already has access.
        '';
      };

      authCredentialFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to a file (managed out of band, e.g. by agenix or sops-nix)
          containing `user:password` for Bitcoin Core RPC. Loaded via
          systemd `LoadCredential` and substituted into config.toml at
          service start. Required when `authType = "USERPASS"`.
        '';
      };

      zmqSequenceEndpoint = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "tcp://127.0.0.1:28336";
        description = ''
          Bitcoin Core's ZMQ `sequence` publisher endpoint. When set,
          Frigate subscribes for sub-100ms mempool ingestion instead of
          polling. Requires bitcoind to be started with
          `-zmqpubsequence=<this-url>`.

          Upstream strongly recommends configuring this whenever
          `electrumBackend` is set, otherwise the backend may notify the
          client of a new transaction via scripthash before Frigate's
          silent-payments notification lands and wallets briefly display
          incorrect amounts.
        '';
      };
    };

    extraSupplementaryGroups = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "acme" ];
      description = ''
        Additional systemd `SupplementaryGroups` for the frigate service.
        `video` and `render` are added unconditionally for GPU access.
        Add `acme` when `sslCert`/`sslKey` live under `/var/lib/acme/`.
      '';
    };

    gpuDevices = mkOption {
      type = types.listOf types.str;
      default = [
        "char-drm rw"
        "/dev/nvidia0 rw"
        "/dev/nvidia1 rw"
        "/dev/nvidiactl rw"
        "/dev/nvidia-uvm rw"
        "/dev/nvidia-uvm-tools rw"
        "/dev/nvidia-modeset rw"
      ];
      description = ''
        systemd `DeviceAllow` entries granting GPU access. The default list
        covers AMD/Intel via `/dev/dri/*` (char-drm) and NVIDIA. Allowing
        a non-existent device is a no-op, so the default is safe.
      '';
    };

    settings = mkOption {
      type = tomlFormat.type;
      default = { };
      example = lib.literalExpression ''
        {
          index.startHeight = 850000;
          scan.batchSize = 200000;
        }
      '';
      description = ''
        Free-form additions to config.toml. Merged on top of the values
        derived from the typed options above. Use this for `[index]`,
        `[scan]`, or any other knob the module does not surface directly.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.bitcoind.authType != "USERPASS" || cfg.bitcoind.authCredentialFile != null;
        message = "services.frigate.bitcoind.authCredentialFile must be set when authType = \"USERPASS\".";
      }
      {
        assertion =
          cfg.bitcoind.authType != "COOKIE" || !cfg.bitcoind.enable || cfg.bitcoind.cookieDir != null;
        message = "services.frigate.bitcoind.cookieDir must be set when authType = \"COOKIE\".";
      }
      {
        assertion = (cfg.ssl == null) || (cfg.sslCert != null && cfg.sslKey != null);
        message = "services.frigate.ssl requires both services.frigate.sslCert and services.frigate.sslKey.";
      }
      {
        assertion = (cfg.tcp != null && cfg.tcp != "") || cfg.ssl != null;
        message = "services.frigate needs at least one of `tcp` or `ssl` configured.";
      }
    ];

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts =
        lib.optional (tcpPortFromUrl != null) tcpPortFromUrl
        ++ lib.optional (sslPortFromUrl != null) sslPortFromUrl;
    };

    # Expose `frigate` and `frigate-cli` on system PATH for operator
    # use. The package wraps both binaries; the systemd unit invokes
    # the same store path internally.
    environment.systemPackages = [ cfg.package ];

    users.users = lib.mkIf (cfg.user == "frigate") {
      frigate = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.dataDir;
      };
    };

    users.groups = lib.mkIf (cfg.group == "frigate") {
      frigate = { };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} - -"
    ]
    ++ lib.optional (configDir != cfg.dataDir) "d ${configDir} 0750 ${cfg.user} ${cfg.group} - -";

    systemd.services.frigate = {
      description = "Frigate silent payments scanning server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      preStart = ''
        install -m 0600 ${configTemplate} ${configDir}/config.toml
      ''
      + lib.optionalString (cfg.bitcoind.authType == "USERPASS") ''
        ${pkgs.replace-secret}/bin/replace-secret \
          '@FRIGATE_BITCOIND_AUTH@' \
          "$CREDENTIALS_DIRECTORY/bitcoind-auth" \
          ${configDir}/config.toml
      '';

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${cfg.package}/bin/frigate --dir ${cfg.dataDir} --network ${cfg.network} --level ${cfg.logLevel}";
        Restart = "on-failure";
        RestartSec = 10;

        LoadCredential = lib.optional (
          cfg.bitcoind.authType == "USERPASS" && cfg.bitcoind.authCredentialFile != null
        ) "bitcoind-auth:${cfg.bitcoind.authCredentialFile}";

        BindReadOnlyPaths = lib.optional (
          cfg.bitcoind.authType == "COOKIE" && cfg.bitcoind.cookieDir != null
        ) cfg.bitcoind.cookieDir;

        ReadWritePaths = [ cfg.dataDir ];

        SupplementaryGroups = [
          "video"
          "render"
        ]
        ++ cfg.extraSupplementaryGroups;
        DevicePolicy = "closed";
        DeviceAllow = cfg.gpuDevices;
        PrivateDevices = false;

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
        SystemCallArchitectures = "native";
      };
    };
  };
}
