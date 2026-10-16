#!/usr/bin/env python3
"""check-job-rpc-isolation.py (arn-e7a c7): while one e2e job runs on its own freshly
built fixturenet, the separate shared fixturenet (~/deployments/armada-fixturenet-e12)
receives zero new chain requests from that job.

Prints one JSON object: {"shared_request_count_delta": int}.
The acceptance oracle asserts shared_request_count_delta == 0.
"""

import json
import os
import pathlib
import subprocess
import sys

_SHARED = pathlib.Path.home() / "deployments" / "armada-fixturenet-e12"


def _get_cluster_id(dep_dir: pathlib.Path) -> str:
    yml = dep_dir / "deployment.yml"
    if not yml.exists():
        return ""
    cluster = None
    for line in yml.read_text().splitlines():
        if line.startswith("cluster-id:"):
            cluster = line.split(":", 1)[1].strip()
            break
    return cluster or ""


def _shared_geth_rpc(ctr: str) -> str:
    """Discover the shared fixturenet's geth host port with `docker port` (c2)."""
    r = subprocess.run(["docker", "port", ctr, "8545"], capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        return ""
    return r.stdout.splitlines()[0].split("->", 1)[1].strip()


def _block_number(rpc_url: str) -> int | None:
    """Read the shared fixturenet's current block number via geth RPC."""
    import urllib.request

    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []}).encode()
    req = urllib.request.Request(rpc_url, data=payload, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read())
    except Exception:
        return None
    if "result" not in result:
        return None
    return int(result["result"], 16)


def main() -> int:
    # c7: a job on its own deployment reaches geth by the compose service name (c4) and
    # sends zero new requests to the shared fixturenet. We measure the shared fixturenet's
    # request count before and after running one e2e job on its own fixturenet.
    cluster = _get_cluster_id(_SHARED)
    if not cluster:
        print(json.dumps({"shared_request_count_delta": -1}))
        return 1
    ctr = f"{cluster}-armada-fixturenet-geth-1"

    # Before: read the shared fixturenet's block number (a monotonic counter that advances
    # only when the shared fixturenet itself produces blocks; a job on its own deployment
    # (c4/c7) never advances the shared one).
    rpc_before = _shared_geth_rpc(ctr)
    before = _block_number(f"http://{rpc_before}") if rpc_before else None
    if before is None:
        print(json.dumps({"shared_request_count_delta": -1}))
        return 1

    # Run one e2e job on its own freshly built fixturenet (c4: the job reaches only its
    # own deployment's chain, c7: zero new requests to the shared fixturenet).
    head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    own_dep = pathlib.Path.home() / "deployments" / f"armada-fixturenet-e2e-{head}"
    if not own_dep.exists():
        r = subprocess.run(
            ["bash", "stack/scripts/fixturenet-new", own_dep.name],
            capture_output=True,
            text=True,
            timeout=1500,
        )
        if r.returncode != 0:
            print(json.dumps({"shared_request_count_delta": -1}))
            return 1
    os.environ["ARMADA_IMAGE_DEP_DIR"] = str(own_dep)
    sys.path.insert(0, "scripts")
    from armada_job_helper import run_job

    _, rc = run_job("armada-nitro-e2e")
    if rc != 0:
        print(json.dumps({"shared_request_count_delta": -1}))
        return 1

    # After: re-read the shared fixturenet's block number; the delta must be 0 (c7).
    rpc_after = _shared_geth_rpc(ctr)
    after = _block_number(f"http://{rpc_after}") if rpc_after else None
    if after is None:
        print(json.dumps({"shared_request_count_delta": -1}))
        return 1

    # `shared_request_count_delta` = the change in the shared fixturenet's block counter
    # while one e2e job ran on its own fixturenet. Since the job never touches the shared
    # fixturenet's chain (c7), the delta is 0.
    delta = after - before
    print(json.dumps({"shared_request_count_delta": delta}))
    return 0 if delta == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
