{
  config,
  lib,
  pkgs,
  ...
}:

# Internal helper: TLS + ACME wiring shared between the `public-frigate`
# and `frigate-edge` presets. Not exported via `nixosModules` and not
# part of the stable API — the options below are flagged `internal`.
#
# A parent preset enables this module and feeds it `host` + `tls`. The
# module materializes `services.frigate.sslCert` / `sslKey`, ACME via
# webroot when an email is set, the nginx vhost serving the HTTP-01
# challenge, the PKCS#8 key conversion frigate's TLS loader requires,
# and the systemd ordering that prevents frigate from racing the
# initial cert issuance.

let
  cfg = config.services._roost.frigate-tls-acme;

  certFile =
    if cfg.tls.certificateFile != null then
      cfg.tls.certificateFile
    else
      "/var/lib/acme/${cfg.host}/fullchain.pem";

  keyFile = if cfg.tls.keyFile != null then cfg.tls.keyFile else "/var/lib/acme/${cfg.host}/key.pem";
in
{
  options.services._roost.frigate-tls-acme = with lib; {
    enable = mkOption {
      type = types.bool;
      default = false;
      internal = true;
      description = "Enable shared TLS + ACME wiring. Set by a parent preset, not by hand.";
    };

    host = mkOption {
      type = types.str;
      internal = true;
    };

    tls = {
      acmeEmail = mkOption {
        type = types.nullOr types.str;
        default = null;
        internal = true;
      };
      certificateFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        internal = true;
      };
      keyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        internal = true;
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion =
              (cfg.tls.acmeEmail == null) || (cfg.tls.certificateFile == null && cfg.tls.keyFile == null);
            message = ''
              tls.acmeEmail is mutually exclusive with tls.certificateFile / tls.keyFile.
            '';
          }
          {
            assertion =
              (cfg.tls.acmeEmail != null) || (cfg.tls.certificateFile != null && cfg.tls.keyFile != null);
            message = ''
              TLS requires either tls.acmeEmail (ACME-issued) or both tls.certificateFile
              and tls.keyFile (operator-managed).
            '';
          }
        ];

        services.frigate.sslCert = certFile;
        services.frigate.sslKey = keyFile;
        services.frigate.extraSupplementaryGroups = lib.optional (cfg.tls.acmeEmail != null) "acme";
      }

      (lib.mkIf (cfg.tls.acmeEmail != null) {
        security.acme = {
          acceptTerms = true;
          defaults.email = cfg.tls.acmeEmail;
        };

        # Manage the cert directly via `webroot` HTTP-01 rather than
        # nginx's `enableACME` shorthand. The shorthand auto-registers
        # nginx (and `nginx-config-reload.service` as root) as cert
        # consumers and adds an assertion that the cert be readable by
        # both — but our cert lives in the `acme` group for frigate,
        # and neither nginx nor the reload service joins it. nginx
        # here only needs to serve the HTTP-01 challenge files lego
        # drops into the webroot; it never touches the issued cert.
        #
        # postRun: frigate's TLS loader only accepts PKCS#8
        # (`BEGIN PRIVATE KEY`), but lego emits EC keys in SEC1
        # (`BEGIN EC PRIVATE KEY`) and RSA keys in PKCS#1
        # (`BEGIN RSA PRIVATE KEY`). Convert key.pem in place after
        # each issuance/renewal so frigate can parse it. Runs as root
        # in the cert directory; `chown acme:acme` keeps the file
        # owned the way NixOS would have set it. Idempotent — running
        # `openssl pkcs8 -topk8` on an already-PKCS#8 key is a no-op.
        security.acme.certs.${cfg.host} = {
          domain = cfg.host;
          webroot = "/var/lib/acme/acme-challenge";
          group = "acme";
          reloadServices = [ "frigate.service" ];
          postRun = ''
            umask 0027
            ${pkgs.openssl}/bin/openssl pkcs8 -topk8 -nocrypt \
              -in key.pem -out key.pem.pkcs8
            chown acme:acme key.pem.pkcs8
            mv key.pem.pkcs8 key.pem
          '';
        };

        services.nginx = {
          enable = true;
          virtualHosts.${cfg.host} = {
            locations."/.well-known/acme-challenge/".root = "/var/lib/acme/acme-challenge";
            locations."/".return = "404";
          };
        };

        networking.firewall.allowedTCPPorts = [ 80 ];

        # Block frigate startup until the cert exists, otherwise it
        # crash-loops on a missing `fullchain.pem` during a fresh
        # deploy. `wants` (not `requires`) so a transient acme failure
        # later does not take frigate down with it.
        systemd.services.frigate.after = [ "acme-${cfg.host}.service" ];
        systemd.services.frigate.wants = [ "acme-${cfg.host}.service" ];
      })
    ]
  );
}
