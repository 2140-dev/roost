{
  pkgs,
  roost,
  extraModules ? [ ],
}:

# End-to-end test for the public-frigate preset, exercised through
# `nixosModules.default`. Boots the entire stack — bitcoind + fulcrum +
# frigate — on regtest, mines 101 blocks, verifies fulcrum is alive on
# the backend port and frigate answers Electrum queries both on its
# plaintext listener and over its native TLS listener.
let
  selfSignedCert =
    pkgs.runCommand "test-self-signed-cert"
      {
        nativeBuildInputs = [ pkgs.openssl ];
      }
      ''
        openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout key.pem -out cert.pem \
          -days 1 -subj "/CN=test.local"
        install -d $out
        install -m 0644 cert.pem $out/cert.pem
        install -m 0644 key.pem $out/key.pem
      '';
in
pkgs.testers.runNixOSTest {
  name = "regtest-preset";

  nodes.machine =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [
        roost.nixosModules.default
      ]
      ++ extraModules;

      services.public-frigate = {
        enable = true;
        host = "test.local";
        network = "regtest";
        # Self-signed cert so frigate's native TLS listener can come up
        # without ACME. The test only verifies the byte-level Electrum
        # response, not chain of trust, so SNI/hostname validation is
        # intentionally skipped on the client side.
        tls.certificateFile = "${selfSignedCert}/cert.pem";
        tls.keyFile = "${selfSignedCert}/key.pem";
      };

      # Regtest overrides on top of the preset's manage-mode bitcoind config.
      # The preset already sets txindex/listen/address/dataDirReadableByGroup;
      # we only need to flip the network and shrink the cache for a lean VM.
      services.bitcoind = {
        regtest = true;
        dbCache = lib.mkForce 100;
        # nix-bitcoin pins the wallet off (production-correct: a public
        # frigate node never needs it). The mining flow below is wallet-
        # driven, so flip it on for the test only. `mkForce` is required
        # because their default isn't `mkDefault`.
        disablewallet = lib.mkForce false;
        # Disable the "is the tip recent?" check that gates IBD exit. In a
        # test VM the clock can drift between boot and mining, leaving the
        # IBD flag stuck at `true` even with 101 freshly-mined blocks. Same
        # trick bitcoind's own functional tests use. Plain assignment (no
        # mkForce) so the preset's `zmqpubsequence=...` line — wired up
        # for frigate 1.5.0's low-latency mempool ingestion — still gets
        # merged in via the `types.lines` accumulation.
        extraConfig = ''
          maxtipage=2147483647
        '';
      };

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
        pkgs.openssl
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

      # 101 blocks: first coinbase matures, fulcrum/frigate get a real tip.
      machine.succeed("${cli} createwallet test")
      addr = machine.succeed("${cli} -rpcwallet=test getnewaddress").strip()
      machine.succeed(f"${cli} generatetoaddress 101 {addr}")

      machine.wait_until_succeeds(
          "${cli} getblockchaininfo | grep -q '\"initialblockdownload\": false'",
          timeout=30,
      )

      # Fulcrum's backend role is fully exercised by the frigate probe
      # below — frigate proxies all non-silent-payments traffic to it,
      # so a `blockchain.headers.subscribe` answered with `height:101`
      # through frigate covers fulcrum's indexing, frigate's backend
      # connection, and frigate's proxy. We only check fulcrum's unit
      # status and listener here.
      machine.wait_for_unit("fulcrum.service")
      machine.wait_for_open_port(60001)

      # Frigate's plaintext listener now sits on the canonical Electrum
      # port (50001). Electrum protocol requires `server.version` as the
      # first message on any new connection; frigate enforces this and
      # rejects anything else with VersionNotNegotiatedException. Share
      # one connection across all three requests via the brace group.
      #
      # Polling loop instead of `wait_until_succeeds` so each attempt's
      # captured response is in the test log — the test driver doesn't
      # surface stdout/stderr from wait-loop attempts otherwise, which
      # makes diagnosing real failures (e.g. a partial response, a
      # different JSON shape, a backend error) effectively impossible.
      machine.wait_for_unit("frigate.service")
      machine.wait_for_open_port(50001)

      import time
      deadline = time.time() + 120
      probe = (
          "{ echo '{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"server.version\",\"params\":[\"test\",\"1.4\"]}'"
          "; echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server.features\",\"params\":[]}'"
          "; echo '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"blockchain.headers.subscribe\",\"params\":[]}'; }"
          " | nc -q 3 127.0.0.1 50001"
      )
      internal = ""
      while time.time() < deadline:
          _status, internal = machine.execute(probe)
          print(f"frigate plaintext probe ({len(internal)}B): {internal!r}")
          if "test.local" in internal and '"height":101' in internal:
              break
          time.sleep(2)
      else:
          raise Exception(
              f"frigate plaintext probe never returned expected content within 120s. "
              f"Last response: {internal!r}"
          )

      assert "test.local" in internal, f"plaintext server.features missing configured host: {internal}"
      assert '"height":101' in internal, f"plaintext blockchain.headers.subscribe missing height:101 (frigate→fulcrum proxy): {internal}"

      # Frigate terminates TLS itself on the public port (50002) using
      # the self-signed cert wired into the preset above. `-ign_eof`
      # keeps s_client reading after stdin closes so we don't race the
      # response against socket teardown. `-servername` provides an
      # explicit SNI matching the self-signed cert. `timeout` bounds the
      # wait; production deployments would use ACME and full chain
      # verification.
      machine.wait_for_open_port(50002)
      public = machine.succeed(
          "{ echo '{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"server.version\",\"params\":[\"test\",\"1.4\"]}'"
          "; echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server.features\",\"params\":[]}'; }"
          " | timeout 5 openssl s_client -connect 127.0.0.1:50002 -servername test.local"
          " -quiet -ign_eof 2>/dev/null || true"
      )
      print("frigate TLS response:", public)
      assert "test.local" in public, f"TLS server.features missing configured host: {public}"
    '';
}
