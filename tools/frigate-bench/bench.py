#!/usr/bin/env python3
"""Measure bitcoind RPC cost as the Frigate workload experiences it.

Frigate's hot loops on bitcoind, in order of how much they show up:

  - mempool-init: `getrawmempool` once, then `getrawtransaction(txid, false)`
    per mempool entry. On mainnet that's tens of thousands of small sequential
    RPCs. This phase dominates the latency a frigate consumer notices on
    first startup or after a service restart.
  - block sync: `getblockhash(h)` + `getblock(hash, 0)` per height. Big payload
    per call (~1-2 MB raw block hex on mainnet), bandwidth-bound rather than
    latency-bound.
  - reorg/probe: `getblockchaininfo`, `getblockhash`, `getblockheader` —
    small calls, infrequent in steady state.
  - steady-state per new tx (with ZMQ active): one `getrawtransaction` per
    transaction frigate is notified about.

This benchmark uses HTTP keep-alive on a single persistent TCP connection,
matching what frigate's Java HTTP client actually does. Naive curl-per-call
benchmarks measure TCP handshake more than RPC cost, which overstates the
latency penalty of a remote backend dramatically.

USAGE
    frigate-bench <rpc-url>   # reads `user:password` from stdin

EXAMPLES
    sudo cat /run/agenix/bitcoind-rpc-creds \\
      | frigate-bench http://127.0.0.1:8332/    # loopback baseline

    sudo cat /run/agenix/bitcoind-rpc-creds \\
      | frigate-bench http://10.42.0.1:8332/   # over a mesh (edge consumer)

OUTPUT
    Per-test: total wall time, calls/sec, ms per call. A final summary
    extrapolates current mempool-init cost from the per-tx sample.
"""
import http.client
import json
import sys
import time
import base64
import random
from urllib.parse import urlparse


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__, file=sys.stderr)
        sys.exit(0 if {"-h", "--help"} & set(sys.argv) else 1)

    url = sys.argv[1]
    creds_line = sys.stdin.readline().strip()
    if ":" not in creds_line:
        sys.exit("error: stdin must be a single `user:password` line")
    user, pw = creds_line.split(":", 1)
    auth_header = "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()

    parsed = urlparse(url)
    host = parsed.hostname
    port = parsed.port or 8332
    if host is None:
        sys.exit(f"error: could not parse host from {url!r}")

    conn = http.client.HTTPConnection(host, port, timeout=60)

    def call(method, params, rid=0):
        body = json.dumps({"jsonrpc": "1.0", "id": str(rid), "method": method, "params": params})
        conn.request("POST", "/", body, {
            "Authorization": auth_header,
            "Content-Type": "application/json",
            "Connection": "keep-alive",
        })
        resp = conn.getresponse()
        data = resp.read()
        if resp.status != 200:
            raise RuntimeError(f"HTTP {resp.status}: {data[:200]!r}")
        decoded = json.loads(data)
        if decoded.get("error"):
            raise RuntimeError(f"RPC error: {decoded['error']}")
        return decoded.get("result")

    def bench(label, n, fn):
        t0 = time.monotonic()
        for i in range(n):
            fn(i)
        dt = time.monotonic() - t0
        per_ms = dt * 1000 / n
        rate = n / dt if dt > 0 else float("inf")
        print(f"  {label:45} n={n:5}  total={dt:7.3f}s   {per_ms:7.3f} ms/call   {rate:7.1f} call/s")
        return per_ms

    # Warm the persistent connection — first call pays TCP+TLS setup, not RPC.
    call("uptime", [])

    print(f"target: {url}")
    print()

    print("[1] pure latency — small request, small response")
    bench("getbestblockhash", 1000, lambda i: call("getbestblockhash", [], i))
    bench("getblockcount",    1000, lambda i: call("getblockcount", [], i))
    print()

    tip_hash = call("getbestblockhash", [])
    tip_height = call("getblockcount", [])

    print("[2] chain meta — frigate calls these during reorg detection")
    bench("getblockhash(tip)",            1000, lambda i: call("getblockhash", [tip_height], i))
    bench("getblockheader(tip, verbose)", 1000, lambda i: call("getblockheader", [tip_hash, True], i))
    print()

    print("[3] big payload — what initial block sync transfers")
    bench("getblock(tip, 0)  raw block hex", 10, lambda i: call("getblock", [tip_hash, 0], i))
    bench("getblock(tip, 1)  txids only",    10, lambda i: call("getblock", [tip_hash, 1], i))
    print()

    print("[4] mempool-init hot loop — the actual frigate startup bottleneck")
    t0 = time.monotonic()
    mempool = call("getrawmempool", [])
    dt = time.monotonic() - t0
    n_mempool = len(mempool)
    print(f"  getrawmempool                                 n=    1  total={dt:7.3f}s   ({n_mempool} txids returned)")

    sample_n = min(1000, n_mempool)
    if sample_n == 0:
        print("  (mempool empty — skipping getrawtransaction sample)")
        return
    sample = random.sample(mempool, sample_n)
    per_tx_ms = bench("getrawtransaction (random sample)", sample_n,
                      lambda i: call("getrawtransaction", [sample[i], False], i))
    print()

    extrapolated = per_tx_ms * n_mempool / 1000.0
    print("[summary] extrapolated mempool init cost on this link:")
    print(f"  current mempool: {n_mempool} transactions")
    print(f"  at {per_tx_ms:.2f} ms/call → ~{extrapolated:.0f} seconds = {extrapolated/60:.1f} minutes")


if __name__ == "__main__":
    main()
