# frigate-bench

A small benchmark that measures bitcoind RPC cost the way Frigate experiences
it: HTTP keep-alive on one persistent TCP connection, hitting the call patterns
Frigate's hot loops actually use. Useful for comparing a loopback deployment
against a remote-backend deployment (e.g. `frigate-edge` over WireGuard) and
seeing how much network latency the deployment actually pays.

## Why this exists

A naive benchmark like `for i in 1..100; do curl ... ; done` measures TCP
handshakes more than it measures RPC cost — every `curl` invocation opens a
fresh connection and pays the 1.5-RTT 3-way-handshake before any data moves.
Frigate's Java HTTP client doesn't do that; it keeps one connection open and
streams requests. This script mirrors that behavior so the numbers reflect
what Frigate actually sees.

## What it measures

| Test | Method | Why |
|---|---|---|
| `getbestblockhash` × 1000 | small in, small out | pure roundtrip latency on a warm connection |
| `getblockcount` × 1000 | small in, small out | same — sanity-check pure latency |
| `getblockhash(tip)` × 1000 | small in, small out | reorg-detection style call |
| `getblockheader(tip, verbose)` × 1000 | small in, ~600 B out | header-fetch style call |
| `getblock(tip, 0)` × 10 | small in, ~1-2 MB raw block hex | initial block sync per-block cost |
| `getblock(tip, 1)` × 10 | small in, ~50-100 KB | block + txids form |
| `getrawmempool` × 1 | small in, ~6 MB on mainnet | bulk mempool listing |
| `getrawtransaction` × 1000 | small in, ~200-2000 B per tx | the inner loop of mempool init / steady-state new-tx scan |

Then extrapolates the per-tx cost across the *full* current mempool to predict
how long a from-scratch mempool init would take.

## Usage

The script reads `user:password` from stdin (so the password doesn't show up in
process listings or shell history) and takes the RPC URL as its only argument.

```sh
# Run directly with python3:
sudo cat /run/agenix/bitcoind-rpc-creds | python3 bench.py http://127.0.0.1:8332/

# Or via the roost flake (uses the python3 in the closure, no host deps):
sudo cat /run/agenix/bitcoind-rpc-creds | nix run github:2140-dev/roost#frigate-bench -- http://127.0.0.1:8332/
```

For an A/B comparison between a loopback consumer and a remote-mesh consumer,
run the same script from both hosts pointing at the same bitcoind instance:

```sh
# Loopback (on the box running bitcoind)
sudo cat /run/agenix/bitcoind-rpc-creds \
  | nix run github:2140-dev/roost#frigate-bench -- http://127.0.0.1:8332/

# Over mesh (on the edge consumer box)
sudo cat /run/agenix/bitcoind-rpc-creds \
  | nix run github:2140-dev/roost#frigate-bench -- http://10.42.0.1:8332/
```

The two outputs are directly comparable per-line.

## Interpreting the numbers

- The **pure-latency tests** show TCP+HTTP overhead per call on the link. With
  keep-alive, this is approximately one RTT per call — so an inter-DC link at
  ~25 ms RTT gives ~25-30 ms per call, while loopback gives ~1 ms.
- The **big-payload tests** are dominated by bandwidth, not latency. The ratio
  between local and remote here tells you how much link throughput hurts.
- The **`getrawtransaction` sample** is the single most relevant signal for
  predicting Frigate startup cost — frigate calls this per mempool entry on
  first start. The summary extrapolates to the current mempool size.

A multi-box arrangement where the edge has a fast link to the backend will
look fine on pure-latency tests but pay ~100-300x in mempool-init wall time
compared to loopback. That's a one-time cost per Frigate restart, not a
steady-state cost.

## Not measured

- **Fulcrum/Electrum protocol** — Frigate proxies non-SP queries to fulcrum,
  but client-driven traffic is low volume in normal operation. If that becomes
  a concern, this script could be extended to probe Electrum over TCP/TLS.
- **ZMQ `sequence` delivery latency** — Frigate's steady-state path receives
  bitcoind tx/block events over ZMQ, then fetches each new tx via RPC. ZMQ
  delivery is push-based and not amenable to synthetic benchmarking; measure
  it from frigate's own logs (`INFO Subscribed to ZMQ sequence publisher`
  appears once subscribed; live tx ingestion latency is visible by comparing
  the bitcoind mempool-accept time with frigate's processing time).
