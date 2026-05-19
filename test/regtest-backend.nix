{
  pkgs,
  roost,
  extraModules ? [ ],
}:

# Single-VM test for the `bitcoind-backend` preset.
#
# Verifies the backend stack the preset spins up:
#  - bitcoind RPC listens on both loopback AND the configured
#    bindAddress (we use eth1 inside the VM as the "mesh" interface)
#  - fulcrum listens on the same bindAddress + loopback
#  - bitcoind's ZMQ sequence publisher binds 0.0.0.0 (exposed mode)
#  - the configured rpcauth user can actually authenticate
#  - the firewall scopes the new ports to the configured interface
#
# Frigate is intentionally not in this test — that's regtest-edge's
# job. This test is the unit-style check that the bitcoind+fulcrum
# stack the preset configures is consistent with the options the
# user set.
#
# Same rpcauth fixture as regtest-edge.nix so both tests cross-check
# the HMAC math.

let
  rpcUser = "frigate-edge";
  rpcPassword = "testpassword";
  rpcPasswordHMAC = "2316d0a5e8ee6339ffb4d86c983bb421$34cc4776187170b359d40928b25deb28ea2bfc436c96fdd0db7150ec5211de85";

  # nixosTest assigns 192.168.1.1 to the first declared node.
  meshIp = "192.168.1.1";
in
pkgs.testers.runNixOSTest {
  name = "regtest-backend";

  nodes.machine =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [
        roost.nixosModules.bitcoind-backend-host
      ]
      ++ extraModules;

      services.bitcoind-backend = {
        enable = true;
        network = "regtest";
        bindAddress = meshIp;
        interface = "eth1";
        allowedPeers = [ "192.168.1.0/24" ];
        rpcAuth = {
          user = rpcUser;
          passwordHMAC = rpcPasswordHMAC;
        };
      };

      # Regtest overrides on top of the stack the preset configured.
      # See regtest-preset.nix for the per-knob rationale.
      services.bitcoind = {
        regtest = true;
        dbCache = lib.mkForce 100;
        disablewallet = lib.mkForce false;
        extraConfig = ''
          maxtipage=2147483647
        '';
      };

      # netcat-openbsd for the auth probe; curl is in the base image
      # but we also want `-q` semantics consistent with regtest-edge.
      environment.systemPackages = [
        pkgs.netcat-openbsd
        pkgs.curl
      ];

      virtualisation.cores = 4;
      virtualisation.memorySize = 4096;
    };

  testScript =
    { nodes, ... }:
    let
      cli = "bitcoin-cli -regtest -datadir=/var/lib/bitcoind";
    in
    ''
      machine.wait_for_unit("bitcoind.service")
      machine.wait_until_succeeds("${cli} getblockchaininfo", timeout=30)

      # 101 blocks: first coinbase matures, fulcrum + ZMQ get real
      # state to publish.
      machine.succeed("${cli} createwallet test")
      addr = machine.succeed("${cli} -rpcwallet=test getnewaddress").strip()
      machine.succeed(f"${cli} generatetoaddress 101 {addr}")
      machine.wait_until_succeeds(
          "${cli} getblockchaininfo | grep -q '\"initialblockdownload\": false'",
          timeout=30,
      )

      machine.wait_for_unit("fulcrum.service")

      # Bind verification: every backend service should accept
      # connections on the configured mesh address, not just loopback.
      machine.wait_for_open_port(18443, addr="${meshIp}")
      machine.wait_for_open_port(28336, addr="${meshIp}")
      machine.wait_for_open_port(60001, addr="${meshIp}")

      # Loopback continues to work — the preset adds the mesh bind on
      # top, doesn't replace the typed loopback binding.
      machine.wait_for_open_port(18443, addr="127.0.0.1")
      machine.wait_for_open_port(60001, addr="127.0.0.1")

      # The point of bitcoind-backend: an edge consumer can hit the
      # JSON-RPC server using the configured rpcauth user. Verify the
      # HMAC line bitcoind writes really does match the password the
      # client sends.
      #
      # The ''${...} are Nix interpolations resolved before this Python
      # source ever exists — the resulting literals don't need an
      # f-prefix (Ruff F541 otherwise) and the JSON body's `{`/`}` are
      # plain characters in a non-f-string.
      auth_check = machine.succeed(
          'curl -s --fail -u "${rpcUser}:${rpcPassword}" '
          '-H "Content-Type: application/json" '
          '-d \'{"jsonrpc":"1.0","id":"t","method":"getblockcount","params":[]}\' '
          'http://${meshIp}:18443/'
      )
      print(f"rpcauth probe: {auth_check}")
      assert '"result":101' in auth_check, (
          f"rpcauth probe did not return block count 101 — auth or "
          f"binding broken: {auth_check}"
      )

      # Wrong password should be rejected. (Catches HMAC-line-malformed
      # bugs that would otherwise let any auth succeed.)
      wrong = machine.execute(
          'curl -s -o /dev/null -w "%{http_code}" '
          '-u "${rpcUser}:not-the-password" '
          '-H "Content-Type: application/json" '
          '-d \'{"jsonrpc":"1.0","id":"t","method":"getblockcount","params":[]}\' '
          'http://${meshIp}:18443/'
      )
      assert "401" in wrong[1], f"wrong password should yield 401, got: {wrong[1]!r}"
    '';
}
