{
  pkgs,
  roost,
  extraModules ? [ ],
}:

# End-to-end test for the public-frigate preset, exercised through
# `nixosModules.default`. Boots the entire stack — bitcoind + electrs +
# frigate + nginx-TLS — on regtest, mines 101 blocks, verifies frigate
# answers Electrum queries both on its internal port and through the
# preset's TLS termination on the public port.
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
        # Self-signed cert so the nginx-TLS layer can come up without ACME.
        # The test only verifies the byte-level Electrum response, not chain
        # of trust, so SNI/hostname validation is intentionally skipped on
        # the client side.
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
        # trick bitcoind's own functional tests use.
        extraConfig = lib.mkForce ''
          maxtipage=2147483647
        '';
      };

      # romanz/electrs takes the network as a CLI flag — nix-bitcoin's module
      # doesn't surface a typed `network` option. `--daemon-dir` points
      # electrs at the regtest cookie subdirectory.
      services.electrs.extraArgs = lib.mkForce "--network regtest --daemon-dir /var/lib/bitcoind/regtest";

      # Frigate's cookie path differs in regtest, and there's no GPU in the
      # test VM. ufsecp falls back to CPU regardless, but being explicit
      # avoids a startup probe.
      services.frigate.bitcoind.cookieDir = lib.mkForce "/var/lib/bitcoind/regtest";
      services.frigate.computeBackend = lib.mkForce "CPU";

      environment.systemPackages = [
        pkgs.netcat-openbsd
        pkgs.socat
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
      machine.wait_for_open_port(50001)
      machine.wait_until_succeeds(
          "echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"blockchain.headers.subscribe\",\"params\":[]}'"
          " | nc -q 1 127.0.0.1 50001"
          " | grep -q '\"height\":101'",
          timeout=120,
      )

      # Frigate answers on its internal port — no TLS, this is what nginx
      # proxies to.
      machine.wait_for_unit("frigate.service")
      machine.wait_for_open_port(57001)
      internal = machine.succeed(
          "echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server.features\",\"params\":[]}'"
          " | nc -q 1 127.0.0.1 57001"
      )
      print("frigate internal response:", internal)
      assert "test.local" in internal, f"internal server.features missing configured host: {internal}"

      # nginx terminates TLS on the public port and stream-proxies to frigate.
      # socat with verify=0 matches the test cert chain; production deployments
      # would use ACME and full verification.
      machine.wait_for_unit("nginx.service")
      machine.wait_for_open_port(50002)
      public = machine.succeed(
          "echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server.features\",\"params\":[]}'"
          " | socat - OPENSSL:127.0.0.1:50002,verify=0"
      )
      print("frigate public TLS response:", public)
      assert "test.local" in public, f"public server.features missing configured host: {public}"
    '';
}
