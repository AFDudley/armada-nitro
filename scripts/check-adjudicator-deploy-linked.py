#!/usr/bin/env python3
"""arn-274 (R1.4): the deploy script links libraries (a) and (b) into the adjudicator on chain.

Starts a fresh local anvil, deploys a local Armada pool (`script/LocalArmada.s.sol`), then runs
the real adjudicator deploy script (`--script`) against it with `--broadcast`. Reads forge's own
broadcast record to find the deployed library and adjudicator addresses, and checks:
  - the deploy script's own exit code is 0 (no revert)
  - both libraries have runtime code at their deployed addresses
  - the adjudicator has runtime code at its deployed address
  - the adjudicator's runtime code carries zero unlinked library placeholders (the Solidity
    linker's `__$<34 hex chars>$__` marker, which appears in bytecode as the ASCII bytes
    `5f5f24` ... `245f5f`)

    python3 scripts/check-adjudicator-deploy-linked.py --script script/Deploy.s.sol

Prints one JSON line: {"deploy_script_exit_code", "linked_libraries_with_code",
"adjudicator_has_code", "unlinked_placeholder_count", ...}. Exits 0 only when the deploy did not
revert, both libraries have code, the adjudicator has code, and no placeholder remains.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]

# anvil's well-known account[0] (deterministic test mnemonic); local-only, never a real key.
_DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
_GROUP_KEY_X = "0xd963041ff4047c2d1d02ffb98e6704935b8093299c8fe26b8c6487b75773e51a"
_GROUP_KEY_Y = "0xc5dd6b069f76a7b59a8bffb5fc6e22cead39ed25c0ef60d34e901f3515606aa1"

# The Solidity linker placeholder `__$<34 hex chars>$__` as ASCII, hex-encoded: "__$" = 5f5f24,
# "$__" = 245f5f, with 68 hex nibbles (34 ASCII chars) of library-identifier hash in between.
_PLACEHOLDER_RE = re.compile(r"5f5f24[0-9a-f]{68}245f5f")

_LIBRARY_NAMES = ("CommitmentHoldings", "PoolSpend")
_ADJUDICATOR_NAME = "ArmadaNitroAdjudicator"


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def _rpc_call(rpc_url: str, method: str, params: list[Any]) -> Any:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(rpc_url, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        payload = json.loads(resp.read())
    if "error" in payload:
        raise RuntimeError(f"{method} failed: {payload['error']}")
    return payload["result"]


def _wait_for_rpc(rpc_url: str, timeout: float = 30.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            _rpc_call(rpc_url, "eth_blockNumber", [])
            return True
        except (urllib.error.URLError, ConnectionError, RuntimeError, OSError):
            time.sleep(0.3)
    return False


def _extract_json_blob(text: str) -> dict[str, Any]:
    """forge script `--json` prints one JSON object per line (broadcast tx records, the final
    run summary, ...); return the first line that parses as JSON and has a "returns" key."""
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "returns" in data:
            return dict(data)
    return {}


def main() -> None:
    parser = argparse.ArgumentParser(description="Check the deploy script links its libraries on chain")
    parser.add_argument("--script", required=True, help="Path to the deploy script")
    args = parser.parse_args()

    script_path = Path(args.script)
    if not script_path.is_absolute():
        script_path = REPO_ROOT / script_path
    if not script_path.exists():
        print(json.dumps({"error": f"script not found: {script_path}"}))
        sys.exit(1)

    port = _free_port()
    rpc_url = f"http://127.0.0.1:{port}"
    anvil = subprocess.Popen(
        ["anvil", "--host", "127.0.0.1", "--port", str(port), "--silent"],
        cwd=str(REPO_ROOT),
    )
    try:
        if not _wait_for_rpc(rpc_url):
            print(json.dumps({"error": "anvil did not become ready"}))
            sys.exit(1)

        # Step 1: deploy a local Armada pool + mock USDC this adjudicator funds against.
        local_env = os.environ.copy()
        local_env["DEPLOYER_KEY"] = _DEPLOYER_KEY
        local_result = subprocess.run(
            [
                "forge",
                "script",
                "script/LocalArmada.s.sol",
                "--rpc-url",
                rpc_url,
                "--broadcast",
                "--slow",
                "--json",
            ],
            cwd=str(REPO_ROOT),
            env=local_env,
            capture_output=True,
            text=True,
            timeout=300,
        )
        local_data = _extract_json_blob(local_result.stdout)
        pool_addr = local_data.get("returns", {}).get("privacyPool", {}).get("value", "")
        usdc_addr = local_data.get("returns", {}).get("usdc", {}).get("value", "")
        if local_result.returncode != 0 or not pool_addr:
            print(
                json.dumps(
                    {
                        "error": "LocalArmada.s.sol failed to deploy a local pool",
                        "local_armada_exit_code": local_result.returncode,
                        "stdout_tail": local_result.stdout[-2000:],
                    }
                )
            )
            sys.exit(1)

        # Step 2: run the real deploy script against that pool.
        deploy_env = os.environ.copy()
        deploy_env.update(
            {
                "ARMADA_POOL": pool_addr,
                "HUB_GROUP_KEY_X": _GROUP_KEY_X,
                "HUB_GROUP_KEY_Y": _GROUP_KEY_Y,
                "HUB_REVOCATION_DELAY": "3600",
                "ARMADA_ASSETS": usdc_addr,
            }
        )
        deploy_result = subprocess.run(
            [
                "forge",
                "script",
                str(script_path),
                "--rpc-url",
                rpc_url,
                "--broadcast",
                "--private-key",
                _DEPLOYER_KEY,
                "--json",
            ],
            cwd=str(REPO_ROOT),
            env=deploy_env,
            capture_output=True,
            text=True,
            timeout=300,
        )
        deploy_script_exit_code = deploy_result.returncode
        deploy_data = _extract_json_blob(deploy_result.stdout)
        adjudicator_addr = deploy_data.get("returns", {}).get("adjudicator", {}).get("value", "")

        # Step 3: read forge's own broadcast record for every address it actually deployed,
        # including the libraries forge links in automatically (never named in Deploy.s.sol).
        chain_id_hex = _rpc_call(rpc_url, "eth_chainId", [])
        chain_id = int(chain_id_hex, 16)
        broadcast_path = REPO_ROOT / "broadcast" / script_path.name / str(chain_id) / "run-latest.json"
        library_addresses: dict[str, str] = {}
        if broadcast_path.exists():
            broadcast = json.loads(broadcast_path.read_text())
            for tx in broadcast.get("transactions", []):
                # `new X()` calls deploy via CREATE; forge deploys external libraries via
                # CREATE2 (deterministic, shareable across every contract that links them).
                if tx.get("transactionType") not in ("CREATE", "CREATE2"):
                    continue
                name = tx.get("contractName")
                addr = tx.get("contractAddress")
                if name in _LIBRARY_NAMES and addr:
                    library_addresses[name] = addr
                if name == _ADJUDICATOR_NAME and addr and not adjudicator_addr:
                    adjudicator_addr = addr

        linked_libraries_with_code = 0
        for name in _LIBRARY_NAMES:
            addr = library_addresses.get(name)
            if not addr:
                continue
            code = _rpc_call(rpc_url, "eth_getCode", [addr, "latest"])
            if code and code != "0x":
                linked_libraries_with_code += 1

        adjudicator_has_code = False
        unlinked_placeholder_count = 0
        if adjudicator_addr:
            code = _rpc_call(rpc_url, "eth_getCode", [adjudicator_addr, "latest"])
            if code and code != "0x":
                adjudicator_has_code = True
                unlinked_placeholder_count = len(_PLACEHOLDER_RE.findall(code[2:].lower()))

        result = {
            "deploy_script_exit_code": deploy_script_exit_code,
            "linked_libraries_with_code": linked_libraries_with_code,
            "adjudicator_has_code": adjudicator_has_code,
            "unlinked_placeholder_count": unlinked_placeholder_count,
            "adjudicator_address": adjudicator_addr,
            "library_addresses": library_addresses,
        }
        print(json.dumps(result))

        ok = (
            deploy_script_exit_code == 0
            and linked_libraries_with_code >= 2
            and adjudicator_has_code
            and unlinked_placeholder_count == 0
        )
        sys.exit(0 if ok else 1)
    finally:
        anvil.terminate()
        try:
            anvil.wait(timeout=5)
        except subprocess.TimeoutExpired:
            anvil.kill()


if __name__ == "__main__":
    main()
