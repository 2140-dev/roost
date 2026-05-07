{
  pkgs,
  nix-bitcoin,
  extraModules ? [ ],
}:

# End-to-end regtest test: spins up bitcoind + electrs + frigate in a single
# VM, mines 101 blocks, and verifies frigate answers an Electrum-protocol
# query. Exercises the bare `services.frigate` module against nix-bitcoin's
# bitcoind/electrs, which is the loose-coupled path a downstream consumer
# would take.
pkgs.testers.runNixOSTest {
  name = "regtest-e2e";

  nodes.machine =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [
        nix-bitcoin.nixosModules.default
        ../modules/frigate.nix
      ]
      ++ extraModules;

      # nix-bitcoin requires an explicit secrets policy whenever bitcoind
      # is enabled through it. The built-in generator is fine for tests.
      nix-bitcoin.generateSecrets = true;

      services.bitcoind = {
        enable = true;
        regtest = true;
        txindex = true;
        dataDirReadableByGroup = true;
        dbCache = 100;
        # Disable the "is the tip recent?" check that gates IBD exit. In a
        # test VM the clock can drift between boot and mining, leaving the
        # IBD flag stuck at `true` even with 101 freshly-mined blocks. That
        # blocks electrs from ever opening its port. Same trick bitcoind's
        # own functional tests use.
        extraConfig = ''
          maxtipage=2147483647
        '';
      };

      # romanz/electrs takes the network as a CLI flag — nix-bitcoin's module
      # doesn't surface a typed `network` option. extraArgs is a single
      # space-concatenated string here, not a list. `--daemon-dir` points
      # electrs at the regtest cookie subdirectory; nix-bitcoin's default
      # is `/var/lib/bitcoind` (correct for mainnet, wrong for regtest).
      services.electrs = {
        enable = true;
        extraArgs = "--network regtest --daemon-dir /var/lib/bitcoind/regtest";
      };

      services.frigate = {
        enable = true;
        network = "regtest";
        host = "test.local";
        # No GPU in the test VM; ufsecp falls back to CPU regardless, but
        # being explicit avoids a startup probe.
        computeBackend = "CPU";
        bitcoind = {
          # bitcoind's regtest cookie lives in the regtest subdirectory.
          cookieDir = "/var/lib/bitcoind/regtest";
          # nix-bitcoin keeps RPC on 8332 across networks. Wire frigate to
          # the same port the daemon actually listens on.
          server = "http://127.0.0.1:${toString config.services.bitcoind.rpc.port}";
        };
      };

      # frigate reads bitcoind's cookie via group access.
      users.users.frigate.extraGroups = [ "bitcoin" ];

      # nc for testScript probes against electrs/frigate.
      environment.systemPackages = [ pkgs.netcat-openbsd ];

      virtualisation.cores = 4;
      virtualisation.memorySize = 4096;
    };

  testScript =
    { nodes, ... }:
    let
      # In regtest, nix-bitcoin lets bitcoind use the chain-default RPC
      # port (18443) rather than the `services.bitcoind.rpc.port` option
      # (which only applies to mainnet). bitcoin-cli with `-regtest` and
      # no `-rpcport` matches that default automatically.
      cli = "bitcoin-cli -regtest -datadir=/var/lib/bitcoind";
    in
    ''
      machine.wait_for_unit("bitcoind.service")
      machine.wait_until_succeeds("${cli} getblockchaininfo", timeout=30)

      # 101 blocks: first coinbase matures, electrs/frigate get a real tip.
      machine.succeed("${cli} createwallet test")
      addr = machine.succeed("${cli} -rpcwallet=test getnewaddress").strip()
      machine.succeed(f"${cli} generatetoaddress 101 {addr}")

      # Confirm bitcoind has actually exited IBD before we wait on electrs.
      # romanz/electrs blocks at startup until `initialblockdownload=false`
      # and won't open its port otherwise — so a stuck IBD flag would show
      # up later as a port-open timeout, masking the real cause.
      machine.wait_until_succeeds(
          "${cli} getblockchaininfo | grep -q '\"initialblockdownload\": false'",
          timeout=30,
      )

      # electrs catches up and serves the new tip on the Electrum protocol.
      machine.wait_for_unit("electrs.service")
      machine.wait_for_open_port(50001)
      machine.wait_until_succeeds(
          "echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"blockchain.headers.subscribe\",\"params\":[]}'"
          " | nc -q 1 127.0.0.1 50001"
          " | grep -q '\"height\":101'",
          timeout=120,
      )

      # frigate reaches steady state and answers an Electrum query.
      machine.wait_for_unit("frigate.service")
      machine.wait_for_open_port(57001)
      response = machine.succeed(
          "echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server.features\",\"params\":[]}'"
          " | nc -q 1 127.0.0.1 57001"
      )
      print("frigate server.features response:", response)
      assert "test.local" in response, f"server.features missing configured host: {response}"
    '';
}
