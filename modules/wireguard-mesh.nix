{
  config,
  lib,
  ...
}:

# Thin WireGuard-mesh wrapper around `networking.wireguard.interfaces`.
#
# The same `peers` block is intended to be defined identically on every
# member host; only `thisHost` and `privateKeyFile` differ per node. The
# module enumerates the peer set, drops the entry matching `thisHost`,
# and emits a wireguard peer for each remainder. Adding a third node
# becomes a one-place edit: a new entry in `peers` plus `thisHost` on
# the new host.
#
# The mesh is point-to-point with /32 peer allowedIPs — no subnets get
# routed through. Public exposure (mesh interface ↔ consumer services)
# is the consumer's concern (scope via `networking.firewall.interfaces.<iface>`).

let
  cfg = config.services.roost.wireguard-mesh;

  # CIDR like "10.42.0.0/24" -> prefix length "24". Falls back to "32"
  # if the input isn't parseable, which the assertion below catches.
  cidrParts = builtins.match "([0-9.]+)/([0-9]+)" cfg.meshCidr;
  cidrPrefixLen = if cidrParts == null then "32" else builtins.elemAt cidrParts 1;

  thisPeer = cfg.peers.${cfg.thisHost} or null;
  interfaceAddress = lib.optionalString (thisPeer != null) "${thisPeer.meshIp}/${cidrPrefixLen}";

  otherPeers = lib.filterAttrs (name: _: name != cfg.thisHost) cfg.peers;

  toWgPeer =
    peer:
    {
      publicKey = peer.publicKey;
      endpoint = peer.endpoint;
      allowedIPs = [ "${peer.meshIp}/32" ];
    }
    // lib.optionalAttrs (peer.persistentKeepalive != null) {
      inherit (peer) persistentKeepalive;
    };
in
{
  options.services.roost.wireguard-mesh = with lib; {
    enable = mkEnableOption "WireGuard mesh between roost hosts";

    interface = mkOption {
      type = types.str;
      default = "wg0";
      description = ''
        Name of the wireguard interface to create. Override if `wg0` is
        already in use on the host for another purpose.
      '';
    };

    thisHost = mkOption {
      type = types.str;
      description = ''
        Short name of the current host within the mesh. Must be a key of
        `peers`. The mesh IP for this host is `peers.<thisHost>.meshIp`.
      '';
    };

    privateKeyFile = mkOption {
      type = types.path;
      description = ''
        Path to this host's WireGuard private key (typically an
        agenix-decrypted path under /run/agenix/). The file must be
        readable by root and contain a single base64-encoded key as
        produced by `wg genkey`.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 51820;
      description = "UDP port WireGuard listens on. Opened in the firewall.";
    };

    meshCidr = mkOption {
      type = types.str;
      example = "10.42.0.0/24";
      description = ''
        CIDR covering every `peers.*.meshIp`. Only the prefix length is
        used (to size the wireguard interface address); the network
        portion is informational and documented for operators.
      '';
    };

    mtu = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = ''
        Override the WireGuard interface MTU. Null = the upstream
        default (1420). Lower this only if the path MTU between mesh
        members is below 1500.
      '';
    };

    peers = mkOption {
      description = ''
        All mesh members keyed by short host name. Define identically
        on every member; the module skips the entry matching `thisHost`
        when emitting wireguard peers.
      '';
      type = types.attrsOf (
        types.submodule {
          options = {
            publicKey = mkOption {
              type = types.str;
              description = "Base64 WireGuard public key as produced by `wg pubkey`.";
            };
            endpoint = mkOption {
              type = types.str;
              example = "1.2.3.4:51820";
              description = ''
                Public reachable endpoint of this peer (`ip:port` or
                `hostname:port`). DNS is resolved once by `wg` at
                interface setup — if the address can change, configure
                `networking.wireguard.dynamicEndpointRefreshSeconds` at
                the consumer level.
              '';
            };
            meshIp = mkOption {
              type = types.str;
              example = "10.42.0.1";
              description = "Mesh-side IPv4 address for this peer. Must fall inside `meshCidr`.";
            };
            persistentKeepalive = mkOption {
              type = types.nullOr types.int;
              default = 25;
              description = ''
                Seconds between keepalive packets to this peer. 25 is the
                conventional "always-on" value — harmless on bare-metal
                links and useful behind NAT or any stateful middlebox.
                Null disables keepalives.
              '';
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.peers ? ${cfg.thisHost};
        message = ''
          services.roost.wireguard-mesh.thisHost ("${cfg.thisHost}") must name
          an entry in services.roost.wireguard-mesh.peers. Existing peers:
          ${lib.concatStringsSep ", " (lib.attrNames cfg.peers)}.
        '';
      }
      {
        assertion = cidrParts != null;
        message = ''
          services.roost.wireguard-mesh.meshCidr ("${cfg.meshCidr}") is not a
          valid IPv4 CIDR. Expected form: "10.42.0.0/24".
        '';
      }
      {
        assertion = (builtins.length (lib.attrNames cfg.peers)) >= 2;
        message = ''
          services.roost.wireguard-mesh.peers must have at least two members
          (this host + at least one remote). A single-node mesh is a no-op.
        '';
      }
    ];

    networking.wireguard.interfaces.${cfg.interface} = {
      ips = [ interfaceAddress ];
      listenPort = cfg.port;
      privateKeyFile = toString cfg.privateKeyFile;
      mtu = cfg.mtu;
      peers = lib.mapAttrsToList (_name: toWgPeer) otherPeers;
    };

    networking.firewall.allowedUDPPorts = [ cfg.port ];
  };
}
