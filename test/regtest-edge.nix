{
  pkgs,
  roost,
  extraModules ? [ ],
}:

# Two-VM end-to-end test for the frigate-edge preset.
#
#  backend VM: nix-bitcoin + public-frigate (full local stack) with
#              `exposeBackends` enabled so bitcoind RPC/ZMQ and fulcrum
#              also listen on the shared subnet for the edge.
#  edge VM:    frigate-edge consuming the backend's services over the
#              shared network. ACME is off (manual cert) so the edge
#              boots without DNS or a real CA.
#
# WireGuard is intentionally not in the loop here — that's covered by
# `test/mesh.nix`. This test exists to verify the frigate-edge preset's
# wiring (USERPASS auth, remote ZMQ, remote electrum, ACME bypass via
# manual cert) and the matching `exposeBackends` bind logic on the
# backend side.
#
# The bitcoind RPC password is a fixed test fixture; the rpcauth HMAC
# below was computed from it via `bitcoind/share/rpcauth/rpcauth.py
# frigate-edge testpassword`. Both halves are committed deliberately so
# the test stays pure (no IFD, no out-of-band state).
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

  rpcUser = "frigate-edge";
  rpcPassword = "testpassword";

  # `salt$hash` computed once via HMAC-SHA256(salt, password). Same
  # algorithm bitcoind/share/rpcauth/rpcauth.py implements. Committable
  # — derives one-way from the plaintext.
  rpcPasswordHMAC = "2316d0a5e8ee6339ffb4d86c983bb421$9b90ff10a12e7df0dee2cd86f827461d3a481f1947a0bae613e4046407ee6ced";

  # `user:password` line the edge feeds frigate via LoadCredential.
  authCredentialFile = pkgs.writeText "edge-bitcoind-auth" "${rpcUser}:${rpcPassword}";

  # Mesh-like IP shared between the two VMs. The nixosTest default
  # subnet is 192.168.1.0/24 with the first declared node at .2; pin
  # the backend's IP via test-driver options so the edge can address it
  # at a known location regardless of order.
  backendIp = "192.168.1.2";
in
pkgs.testers.runNixOSTest {
  name = "regtest-edge";

  nodes.backend =
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
        host = "backend.test.local";
        network = "regtest";
        tls.certificateFile = "${selfSignedCert}/cert.pem";
        tls.keyFile = "${selfSignedCert}/key.pem";

        exposeBackends = {
          enable = true;
          bindAddress = backendIp;
          interface = "eth1";
          allowedPeers = [ "192.168.1.0/24" ];
          rpcAuth = {
            user = rpcUser;
            passwordHMAC = rpcPasswordHMAC;
          };
        };
      };

      # Same regtest plumbing as `regtest-preset.nix`. See that file for
      # the per-knob rationale.
      services.bitcoind = {
        regtest = true;
        dbCache = lib.mkForce 100;
        disablewallet = lib.mkForce false;
        extraConfig = ''
          maxtipage=2147483647
        '';
      };
      services.frigate.bitcoind.cookieDir = lib.mkForce "/var/lib/bitcoind/regtest";
      services.frigate.computeBackend = lib.mkForce "CPU";
      services.frigate.bitcoind.server = lib.mkForce "http://127.0.0.1:${toString config.services.bitcoind.rpc.port}";

      networking.firewall.allowedTCPPorts = [ 50001 ];

      virtualisation.cores = 4;
      virtualisation.memorySize = 4096;
    };

  nodes.edge =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [
        roost.nixosModules.frigate-edge
      ]
      ++ extraModules;

      services.frigate-edge = {
        enable = true;
        host = "edge.test.local";
        network = "regtest";
        tls.certificateFile = "${selfSignedCert}/cert.pem";
        tls.keyFile = "${selfSignedCert}/key.pem";

        backend = {
          bitcoind = {
            rpcUrl = "http://${backendIp}:18443";
            inherit authCredentialFile;
            zmqSequenceEndpoint = "tcp://${backendIp}:28336";
          };
          electrumUrl = "tcp://${backendIp}:60001";
        };
      };

      # GPU isn't present in the test VM; pin to CPU compute. Matches
      # what regtest-preset does on the backend.
      services.frigate.computeBackend = lib.mkForce "CPU";

      virtualisation.cores = 2;
      virtualisation.memorySize = 2048;
    };

  testScript =
    { nodes, ... }:
    let
      cli = "bitcoin-cli -regtest -datadir=/var/lib/bitcoind";
    in
    ''
      start_all()

      # Backend comes up first; mine the chain so the edge has something
      # real to scan.
      backend.wait_for_unit("bitcoind.service")
      backend.wait_until_succeeds("${cli} getblockchaininfo", timeout=30)

      backend.succeed("${cli} createwallet test")
      addr = backend.succeed("${cli} -rpcwallet=test getnewaddress").strip()
      backend.succeed(f"${cli} generatetoaddress 101 {addr}")

      backend.wait_until_succeeds(
          "${cli} getblockchaininfo | grep -q '\"initialblockdownload\": false'",
          timeout=30,
      )

      backend.wait_for_unit("fulcrum.service")
      backend.wait_for_open_port(60001, addr="${backendIp}")

      # bitcoind RPC and ZMQ should also be reachable from the second
      # interface thanks to exposeBackends.
      backend.wait_for_open_port(18443, addr="${backendIp}")
      backend.wait_for_open_port(28336, addr="${backendIp}")

      # Edge can talk to the backend via the shared subnet.
      edge.wait_until_succeeds("nc -z ${backendIp} 60001", timeout=30)
      edge.wait_until_succeeds("nc -z ${backendIp} 18443", timeout=30)

      # Frigate-edge should authenticate against bitcoind (USERPASS,
      # plaintext fed via LoadCredential), subscribe to remote ZMQ, and
      # accept Electrum traffic on both its plaintext and TLS listeners.
      edge.wait_for_unit("frigate.service")
      edge.wait_for_open_port(50001)
      edge.wait_for_open_port(50002)

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
          _status, internal = edge.execute(probe)
          print(f"frigate-edge plaintext probe ({len(internal)}B): {internal!r}")
          if "edge.test.local" in internal and '"height":101' in internal:
              break
          time.sleep(2)
      else:
          raise Exception(
              f"frigate-edge plaintext probe never returned expected content. "
              f"Last response: {internal!r}"
          )

      assert "edge.test.local" in internal, f"edge server.features missing host: {internal}"
      assert '"height":101' in internal, (
          f"edge blockchain.headers.subscribe missing height:101 — fulcrum proxy "
          f"or remote backend wiring broken: {internal}"
      )
    '';
}
