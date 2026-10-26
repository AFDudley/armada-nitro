#!/usr/bin/env python3
"""stack/scripts/verify-linked-libraries.py — arn-831 c1/c2: prove the foundry-linked
Poseidon library addresses hold real code on a real fixturenet.

Stands up or restores the fixturenet from the warm snapshot (stack/scripts/fixturenet-new,
the "normal way"), which runs the production deploy path (script/Deploy.s.sol via the
armada_nitro module). After the deploy, the script queries the live chain via the geth RPC
to check the linked library code. Tearing down on exit.

  --address 0x...        check one linked-library address, report code_size
  --all-foundry-links    check every foundry.toml-linked library address, report empty_library_count

The script prints exactly one JSON line to stdout:
    --address:  {"address": "0x...", "code_size": N}
    --all-foundry-links:
        {"libraries": [{"address": "0x...", "code_size": N}, ...], "empty_library_count": N}
"""

from __future__ import annotations

import json
import os
import re
import sys
import subprocess
import uuid
from pathlib import Path

# ---- paths -----------------------------------------------------------------
SCRIPT = Path(__file__).resolve()
REPO_ROOT = SCRIPT.parents[2]
TMPDIR = REPO_ROOT / ".scratch"
JOB_NAME = "armada-nitro-scenario"  # the job that runs the fixturenet's production deploy path


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def run(cmd: list[str], env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    run_env = env if env is not None else os.environ.copy()
    log("+ " + " ".join(cmd))
    p = subprocess.run(cmd, env=run_env, capture_output=True, text=True)
    if p.stdout:
        log(p.stdout)
    if p.stderr:
        log(p.stderr)
    if p.returncode != 0:
        raise RuntimeError(f"command failed (exit {p.returncode}): {' '.join(cmd)}")
    return p


def find_links(foundry_toml: Path) -> list[dict[str, str]]:
    """Parse the `libraries = [...]` array in foundry.toml. Each entry is
    `path:LibraryName:0xaddress`. Returns the linked library addresses."""
    text = foundry_toml.read_text()
    # Match the libraries array block.
    m = re.search(r"libraries\s*=\s*\[(?P<block>.*?)\]", text, re.DOTALL)
    if not m:
        return []
    links = []
    for entry in re.findall(r'"([^"]+)"', m.group("block")):
        parts = entry.split(":")
        if len(parts) == 3:
            path, lib, addr = parts
            links.append({"path": path, "library": lib, "address": addr})
    return links


def _resolve_rpc(dep: Path) -> str:
    """Find the random published geth port via `docker port` (arn-e7a c2). The job itself
    reaches geth by the compose service name (no host networking); this script queries the
    chain directly, so it needs the host-side published port."""
    import subprocess as _sp

    # The geth container is named "<cluster-id>-armada-fixturenet-geth-1".
    # cluster-id comes from the deployment's deployment.yml.
    # But the c1/c2 script runs on the host, so it needs to find the published port.
    # The deployment's cluster-id is in deployment.yml. Let's read it.
    # Read the cluster-id from the deployment's deployment.yml.
    # Actually, the c1/c2 script stands up the fixturenet via fixturenet-new, so the
    # deployment's deployment.yml has the cluster-id.
    # Let's use `docker port <container> 8545` to find the published port.
    # The container name is "<cluster-id>-armada-fixturenet-geth-1".
    # We need the cluster-id. Let's read it from the deployment's deployment.yml.
    # The deployment dir has a deployment.yml with cluster-id.
    cluster = ""
    dep_yml = dep / "deployment.yml"
    if dep_yml.exists():
        # Parse the cluster-id from deployment.yml.
        # deployment.yml is a YAML file with cluster-id: <id>.
        # Let's read it safely.
        content = dep_yml.read_text()
        # Extract cluster-id via regex (avoiding a full YAML parse dependency).
        import re as _re

        m = _re.search(r"^cluster-id:\s*(\S+)", content, _re.MULTILINE)
        if m:
            cluster = m.group(1)
    if not cluster:
        raise RuntimeError(f"no cluster-id in {dep}/deployment.yml")
    ctr = f"{cluster}-armada-fixturenet-geth-1"
    p = _sp.run(["docker", "port", ctr, "8545"], capture_output=True, text=True)
    line = p.stdout.strip()
    if not line:
        raise RuntimeError(f"no published 8545 for {ctr}")
    # docker port returns "<ip>:<host_port> -> <container_port>"
    if " -> " in line:
        host_port = line.split(" -> ")[0]
        # host_port is like "0.0.0.0:34567"
        port = host_port.split(":")[-1]
        return f"http://127.0.0.1:{port}"
    return f"http://{line}"


def _query_code_size(rpc: str, address: str) -> int:
    """Query the chain for the code size at `address` via eth_getCode."""
    import json
    import urllib.request

    # Build the JSON-RPC request.
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getCode", "params": [address, "latest"]})
    req = urllib.request.Request(rpc, data=payload.encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        result = json.loads(r.read())
    code = result.get("result", "0x")
    # code is a 0x-prefixed hex string. The code size is len(code)//2 bytes (minus the 0x prefix).
    if code.startswith("0x"):
        code_size = (len(code) - 2) // 2
    else:
        code_size = 0
    return code_size


def check_address(rpc: str, address: str) -> dict[str, object]:
    """Check one linked-library address and report its code size."""
    code_size = _query_code_size(rpc, address)
    return {"address": address, "code_size": code_size}


def check_all_foundry(rpc: str) -> dict[str, object]:
    """Check every foundry.toml-linked address; report the count of empty ones."""
    links = find_links(REPO_ROOT / "foundry.toml")
    if not links:
        raise RuntimeError("no libraries found in foundry.toml")
    # The c2 spec says "each library address named in the project's linking settings holds code".
    # We need to check each linked address on the chain.
    # The c1/c2 script stands up the fixturenet, so the code should be present after the
    # production deploy path places the libraries.
    results = []
    empty = 0
    for link in links:
        code_size = _query_code_size(rpc, link["address"])
        results.append({"address": link["address"], "code_size": code_size})
        if code_size == 0:
            empty += 1
    return {
        "libraries": results,
        "empty_library_count": empty,
    }


def teardown(dep: Path, env: dict[str, str]) -> None:
    """Guarded teardown on exit (arn-eb0): the shared fixturenet-teardown routine unmounts the
    tmpfs RAM disk, stops the deployment (laconic-so stop --delete-volumes), and removes the
    directory -- matching verify-r2-deposit-conserves.py's own pattern."""
    try:
        subprocess.run(
            ["bash", str(REPO_ROOT / "stack/scripts/fixturenet-teardown"), str(dep)],
            env=env,
        )
    except Exception as exc:  # pragma: no cover -- best-effort teardown
        log(f"teardown failed (continuing): {exc}")


def main() -> int:
    import argparse
    import time

    parser = argparse.ArgumentParser(
        description="Verify foundry-linked libraries hold code on a real fixturenet"
    )
    parser.add_argument("--address", help="single linked-library address to check")
    parser.add_argument(
        "--all-foundry-links", action="store_true", help="check every foundry.toml-linked address"
    )
    args = parser.parse_args()
    if not args.address and not args.all_foundry_links:
        parser.print_help()
        return 1
    if args.address and args.all_foundry_links:
        log("verify-linked-libraries.py: --address and --all-foundry-links are mutually exclusive; use one")
        return 1

    name = f"linked-libraries-{int(time.time())}-{uuid.uuid4().hex[:6]}"
    dep = Path(os.environ["HOME"]) / "deployments" / name
    env = os.environ.copy()
    env["DEP"] = str(dep)
    env["TMPDIR"] = str(TMPDIR)

    # Stand up or restore the fixturenet from the warm snapshot (the normal way).
    TMPDIR.mkdir(exist_ok=True)
    env["ARMADA_IMAGE_TAG"] = run(["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"]).stdout.strip()
    run(["bash", str(REPO_ROOT / "stack/scripts/fixturenet-new"), name], env=env)

    try:
        rpc = _resolve_rpc(dep)
        if args.address:
            outcome = check_address(rpc, args.address)
        else:
            outcome = check_all_foundry(rpc)
    except RuntimeError as exc:
        # On failure, still print a JSON line with a non-zero exit code so the spec's
        # `exit_code == 0` check fails appropriately.
        print(json.dumps({"error": str(exc)}))
        return 1
    finally:
        try:
            teardown(dep, env)
        except RuntimeError as exc:
            log(f"teardown failed (result line still printed): {exc}")

    print(json.dumps(outcome))
    return 0


if __name__ == "__main__":
    sys.exit(main())
