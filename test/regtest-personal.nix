{
  pkgs,
  roost,
  extraModules ? [ ],
}:

# End-to-end test for the personal-frigate preset, exercised through
# `nixosModules.personal-frigate-host`. Boots the entire stack —
# bitcoind + electrs + frigate — on regtest, mines 101 blocks, then
# probes electrs directly and frigate's plaintext Electrum listener to
# verify the full personal-deployment chain.
pkgs.testers.runNixOSTest {
  name = "regtest-personal";

  nodes.machine =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [
        roost.nixosModules.personal-frigate-host
      ]
      ++ extraModules;

      services.personal-frigate = {
        enable = true;
        network = "regtest";
      };

      # Regtest overrides on top of the preset's manage-mode bitcoind config.
      # The preset already sets txindex/listen/address/dataDirReadableByGroup;
      # we only need to flip the network and shrink the cache for a lean VM.
      services.bitcoind = {
        regtest = true;
        dbCache = lib.mkForce 100;
        # nix-bitcoin pins the wallet off. The mining flow below is wallet-
        # driven, so flip it on for the test only. `mkForce` is required
        # because their default isn't `mkDefault`.
        disablewallet = lib.mkForce false;
        # Disable the "is the tip recent?" check that gates IBD exit. In a
        # test VM the clock can drift between boot and mining, leaving the
        # IBD flag stuck at `true` even with 101 freshly-mined blocks. Same
        # trick bitcoind's own functional tests use. Plain assignment (no
        # mkForce) so the preset's `zmqpubsequence=...` line still gets
        # merged in via the `types.lines` accumulation.
        extraConfig = ''
          maxtipage=2147483647
        '';
      };

      # regtest auto-flips via services.bitcoind.regtest -> bitcoind.makeNetworkName

      # Frigate's cookie path differs in regtest, and there's no GPU in the
      # test VM. ufsecp falls back to CPU regardless, but being explicit
      # avoids a startup probe.
      services.frigate.bitcoind.cookieDir = lib.mkForce "/var/lib/bitcoind/regtest";
      services.frigate.computeBackend = lib.mkForce "CPU";

      # The preset hardcodes mainnet's RPC port (8332). In regtest, bitcoind
      # binds the chain-default port (18443). Point frigate at whatever
      # nix-bitcoin actually configured.
      services.frigate.bitcoind.server = lib.mkForce "http://127.0.0.1:${toString config.services.bitcoind.rpc.port}";

      environment.systemPackages = [
        pkgs.netcat-openbsd
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

      # 101 blocks: first coinbase matures, electrs/frigate get a real tip.
      machine.succeed("${cli} createwallet test")
      addr = machine.succeed("${cli} -rpcwallet=test getnewaddress").strip()
      machine.succeed(f"${cli} generatetoaddress 101 {addr}")

      machine.wait_until_succeeds(
          "${cli} getblockchaininfo | grep -q '\"initialblockdownload\": false'",
          timeout=30,
      )

      machine.wait_for_unit("electrs.service")
      machine.wait_for_open_port(60001)

      # Direct probe against electrs isolates backend health from the
      # frigate→electrs proxy below — a failure here pins the problem on
      # electrs (or its bitcoind dependency), not on frigate.
      #
      # Polling loop instead of `wait_until_succeeds` so each attempt's
      # captured response is in the test log — the test driver doesn't
      # surface stdout/stderr from wait-loop attempts otherwise, which
      # makes diagnosing real failures effectively impossible.
      import time
      deadline = time.time() + 120
      electrs_probe = (
          "echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"blockchain.headers.subscribe\",\"params\":[]}'"
          " | nc -q 1 127.0.0.1 60001"
      )
      electrs_resp = ""
      while time.time() < deadline:
          _status, electrs_resp = machine.execute(electrs_probe)
          print(f"electrs direct probe ({len(electrs_resp)}B): {electrs_resp!r}")
          if '"height":101' in electrs_resp:
              break
          time.sleep(2)
      else:
          raise Exception(
              f"electrs direct probe never returned height:101 within 120s. "
              f"Last response: {electrs_resp!r}"
          )

      assert '"height":101' in electrs_resp, f"electrs direct probe missing height:101: {electrs_resp}"

      # Frigate's plaintext listener sits on the canonical Electrum port
      # (50001), bound to the preset's default `listenAddress` of
      # 127.0.0.1. Electrum protocol requires `server.version` as the
      # first message on any new connection; frigate enforces this and
      # rejects anything else with VersionNotNegotiatedException. Share
      # one connection across all three requests via the brace group.
      machine.wait_for_unit("frigate.service")
      machine.wait_for_open_port(50001, addr="127.0.0.1")

      deadline = time.time() + 120
      probe = (
          "{ echo '{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"server.version\",\"params\":[\"test\",\"1.4\"]}'"
          "; echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server.features\",\"params\":[]}'"
          "; echo '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"blockchain.headers.subscribe\",\"params\":[]}'; }"
          " | nc -q 3 127.0.0.1 50001"
      )
      frigate_resp = ""
      while time.time() < deadline:
          _status, frigate_resp = machine.execute(probe)
          print(f"frigate plaintext probe ({len(frigate_resp)}B): {frigate_resp!r}")
          if "localhost" in frigate_resp and '"height":101' in frigate_resp:
              break
          time.sleep(2)
      else:
          raise Exception(
              f"frigate plaintext probe never returned expected content within 120s. "
              f"Last response: {frigate_resp!r}"
          )

      assert "localhost" in frigate_resp, f"plaintext server.features missing default host: {frigate_resp}"
      assert '"height":101' in frigate_resp, f"plaintext blockchain.headers.subscribe missing height:101 (frigate→electrs proxy): {frigate_resp}"
    '';
}
