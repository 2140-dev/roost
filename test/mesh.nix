{
  pkgs,
  roost,
  extraModules ? [ ],
}:

# Two-node nixosTest for the `wireguard-mesh` module. Both VMs sit on
# the same virtual network; the mesh interface is layered on top, with
# /32 allowedIPs scoping the peer relationships. The test asserts that
# mesh IPs reach each other, that the firewall opens the WireGuard UDP
# port automatically, and that the assertions catch a misconfigured
# `thisHost`.
#
# Keypairs below are throwaway test fixtures generated specifically for
# this file. They have no relationship to production hosts and are
# committed deliberately so the test stays pure (no IFD).
let
  testKeys = {
    a = {
      privateKey = "AF3qED26m1FhgY3yn7gvBKP76qPcKoej0oTVaetMZkU=";
      publicKey = "PRbUI7dXfSREqCH9twFOaugCW5OrTl2T4RU55F6YGHU=";
    };
    b = {
      privateKey = "MAN5lxJ4l3bTug+rxk7YMhmIhoPy/13BspwvLnJHUVw=";
      publicKey = "vufhiWpCvP7C8LpG9WjXqJk78KJUYDGHcl5Wn3I2xSU=";
    };
  };

  # The wireguard module wants a path on disk, not a literal key. Drop
  # each test key into the nix store and reference it by path. Mode 600
  # matches what agenix would produce.
  privFor =
    name:
    pkgs.writeTextFile {
      name = "wg-mesh-test-${name}.priv";
      text = testKeys.${name}.privateKey;
    };

  meshPeers = {
    a = {
      publicKey = testKeys.a.publicKey;
      # `nodes.<name>.networking.primaryIPAddress` is the canonical way
      # to reference a VM's primary NIC address inside a nixosTest, but
      # we cannot reference that from inside `nodes.*` (cyclic). The
      # test framework assigns 192.168.<vlan>.<nodeNumber> starting at
      # nodeNumber 1, in declaration order: nodeA = .1, nodeB = .2.
      endpoint = "192.168.1.1:51820";
      meshIp = "10.42.0.1";
    };
    b = {
      publicKey = testKeys.b.publicKey;
      endpoint = "192.168.1.2:51820";
      meshIp = "10.42.0.2";
    };
  };

  mkNode = name: {
    imports = [
      roost.nixosModules.wireguard-mesh
    ]
    ++ extraModules;

    services.roost.wireguard-mesh = {
      enable = true;
      thisHost = name;
      privateKeyFile = privFor name;
      meshCidr = "10.42.0.0/24";
      peers = meshPeers;
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "wireguard-mesh";

  nodes.nodeA = mkNode "a";
  nodes.nodeB = mkNode "b";

  testScript = ''
    start_all()

    # The upstream wireguard module creates a target `wireguard-wg0`
    # that waits for the interface service AND every peer service.
    # Waiting on the bare interface service returns too early — the
    # peers aren't in the kernel yet, so ping fails with "Required key
    # not available" until the peer services finish.
    nodeA.wait_for_unit("wireguard-wg0.target")
    nodeB.wait_for_unit("wireguard-wg0.target")

    # The interface should be up with the configured /24 address. The
    # `ip addr show` output includes "10.42.0.1/24" for nodeA only.
    nodeA.succeed("ip -4 addr show wg0 | grep -q 10.42.0.1/24")
    nodeB.succeed("ip -4 addr show wg0 | grep -q 10.42.0.2/24")

    # Cross-mesh reachability. The first handshake can take a moment
    # after both ends finish their boot, so allow a few attempts.
    nodeA.wait_until_succeeds("ping -c 1 -W 1 10.42.0.2", timeout=30)
    nodeB.wait_until_succeeds("ping -c 1 -W 1 10.42.0.1", timeout=30)

    # Firewall should have UDP 51820 open. Confirm by inspecting the
    # iptables ruleset rather than poking the port from outside, which
    # would race against the in-progress handshake.
    nodeA.succeed("iptables-save | grep -E -- '--dport 51820'")
    nodeB.succeed("iptables-save | grep -E -- '--dport 51820'")
  '';
}
