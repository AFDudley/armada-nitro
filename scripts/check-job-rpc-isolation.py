#!/usr/bin/env python3
"""check-job-rpc-isolation.py (arn-e7a c7/c10).

Clause c10: while one e2e job runs on its own freshly built fixturenet, the
shared fixturenet (~/deployments/armada-fixturenet-e12) receives zero new chain
requests from that job.

This oracle measures the TRANSACTIONS that land on the shared chain while the
job runs on its OWN fixturenet. Transactions are state-changing chain requests.
This is NOT the block-number delta: the shared chain makes empty blocks on a
slot schedule whether or not anyone calls it, so a block-number delta is never
zero and never proved isolation. A transaction count is zero while the shared
chain is idle, and rises when a client sends it funding/deploy transactions.

The oracle does NOT require the job to exit 0 -- job success is a separate
deliverable (for armada-nitro-e2e it is arn-b27).

Prints one JSON object: {"shared_request_count_delta": int}.
The acceptance oracle asserts shared_request_count_delta == 0.

Sensitivity (how to see a non-zero count): send one transaction to the shared
RPC, or run the same job with HUB_RPC pointed at the shared geth; the next
shared block then carries that transaction and the count rises above 0. A
value of -1 is a sentinel for a precondition that could not be read (the shared
fixturenet is down, or the own fixturenet did not build).

No arbitrary build timeout: the spec-level timeout_seconds bounds the whole
oracle. build_or_reuse reuses a running own fixturenet a sibling oracle built.
"""

import json
import os
import pathlib
import subprocess
import sys
import urllib.request

_SHARED = pathlib.Path.home() / "deployments" / "armada-fixturenet-e12"
_PROBE_JOB = "armada-nitro-e2e"


def _cluster_id(dep: pathlib.Path) -> str:
    yml = dep / "deployment.yml"
    if not yml.exists():
        return ""
    for line in yml.read_text().splitlines():
        if line.startswith("cluster-id:"):
            return line.split(":", 1)[1].strip()
    return ""


def _container_up(name: str) -> bool:
    r = subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True)
    return r.returncode == 0 and name in r.stdout.splitlines()


def _dep_running(dep: pathlib.Path) -> bool:
    cluster = _cluster_id(dep)
    return bool(cluster) and _container_up(f"{cluster}-armada-fixturenet-geth-1")


def _geth_host_rpc(cluster: str) -> str:
    """Discover the geth host RPC with `docker port` (arn-e7a c2/c3)."""
    ctr = f"{cluster}-armada-fixturenet-geth-1"
    r = subprocess.run(["docker", "port", ctr, "8545"], capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        return ""
    return "http://" + r.stdout.splitlines()[0].split("->", 1)[1].strip()


def _rpc(url: str, method: str, params: list[object]) -> object:
    data = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())["result"]


def _block_number(url: str) -> int:
    res = _rpc(url, "eth_blockNumber", [])
    assert isinstance(res, str), f"eth_blockNumber result not a string: {res!r}"
    return int(res, 16)


def _block_tx_count(url: str, n: int) -> int:
    blk = _rpc(url, "eth_getBlockByNumber", [hex(n), False])
    if not isinstance(blk, dict):
        return 0
    txs = blk.get("transactions", [])
    return len(txs) if isinstance(txs, list) else 0


def _own_name() -> str:
    head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    return os.environ.get("E2E_FIXTURENET_NAME", f"armada-fixturenet-e2e-{head}")


def _build_or_reuse(name: str) -> tuple[pathlib.Path, bool]:
    dep = pathlib.Path.home() / "deployments" / name
    if dep.exists() and _dep_running(dep):
        return dep, True
    r = subprocess.run(["bash", "stack/scripts/fixturenet-new", name])
    return dep, (r.returncode == 0 and _dep_running(dep))


def main() -> int:
    if not _dep_running(_SHARED):
        print(json.dumps({"shared_request_count_delta": -1}))
        return 1
    shared_rpc = _geth_host_rpc(_cluster_id(_SHARED))
    if not shared_rpc:
        print(json.dumps({"shared_request_count_delta": -1}))
        return 1

    name = _own_name()
    dep, built = _build_or_reuse(name)
    if not built:
        print(json.dumps({"shared_request_count_delta": -1}))
        return 1

    before = _block_number(shared_rpc)

    # Run one e2e job on the OWN deployment. The job's exit code is not required.
    os.environ["ARMADA_IMAGE_DEP_DIR"] = str(dep)
    sys.path.insert(0, "scripts")
    from armada_job_helper import run_job

    run_job(_PROBE_JOB)

    after = _block_number(shared_rpc)

    # Count transactions that landed on the SHARED chain while the job ran on its
    # own fixturenet. Under isolation this is 0: every shared block is empty.
    delta = sum(_block_tx_count(shared_rpc, n) for n in range(before + 1, after + 1))

    print(json.dumps({"shared_request_count_delta": delta}))
    return 0 if delta == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
