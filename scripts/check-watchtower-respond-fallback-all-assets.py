#!/usr/bin/env python3
"""Behavioral check (arn-5a6): when `concludeAndTransferAllAssets` would revert,
WatchtowerScenario.s.sol's `respond()` falls back to per-asset `transfer(assetIndex, ...)`
for EVERY asset index in the outcome -- not only assetIndex 0.

Runs entirely against a fresh, local anvil node (never the shared fixturenet):
  1. deploys a three-asset channel (script/WatchtowerFallbackSetup.s.sol's `setup(true)` --
     the middle asset's token is set to always-revert on transfer; the third asset's token
     is left working);
  2. the hub challenges the stale, co-signed state N (script/WatchtowerScenario.s.sol's
     `openAndChallenge(uint256)`, unmodified);
  3. the watchtower answers (script/WatchtowerScenario.s.sol's `respond(uint256)`, the
     function under test): since the middle asset's token refuses its transfer, the
     `concludeAndTransferAllAssets` probe reverts, so `respond` finalizes via `conclude` and
     pays out each asset index in turn -- the first and third assets still get paid even when
     the middle one's payout reverts.
  4. reads the adjudicator's `AllocationUpdated` events and reports the first-asset (USDC) and
     third-asset paid-out amounts.

Prints JSON: {"first_asset_payout": <int>, "third_asset_payout": <int>}.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
from typing import Any

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANVIL_PORT_BASE = int(os.environ.get("ANVIL_PORT_BASE", "8646"))

# anvil/hardhat's published, widely-documented dev mnemonic ("test test ... junk") accounts 0-2 --
# the same keys docs/ENVIRONMENT.md and env/reconciler/modules/_wallet.py derive from for every
# other local-anvil fixture in this repo.
DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
USER_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
HUB_KEY = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"

CHALLENGE_DURATION = "5"
STATE_N_USER = "1000000"
STATE_N1_USER = "2000000"
HUB_RESERVE = "500000"
SECOND_ASSET_AMOUNT = "300000"
THIRD_ASSET_AMOUNT = "400000"

# keccak256("AllocationUpdated(bytes32,address,uint256,uint256)"), computed with `cast keccak`.
ALLOC_UPDATED_TOPIC = "0x0e704ff99caf8149a27bcf6efefe38c2d476854d60a730de564066947ebc9b99"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def run(cmd: list[str], env: dict[str, str]) -> "subprocess.CompletedProcess[str]":
    log("+ " + " ".join(cmd))
    p = subprocess.run(cmd, cwd=REPO_ROOT, env=env, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"command failed (exit {p.returncode}): {' '.join(cmd)}\n{p.stdout}\n{p.stderr}")
    return p


def forge_script(
    script: str,
    contract: str,
    sig: str,
    args: list[str],
    broadcast: bool,
    rpc_url: str,
    env: dict[str, str],
) -> "subprocess.CompletedProcess[str]":
    cmd = [
        "forge",
        "script",
        script,
        "--target-contract",
        contract,
        "--sig",
        sig,
        *args,
        "--rpc-url",
        rpc_url,
    ]
    if broadcast:
        cmd.append("--broadcast")
    return run(cmd, env)


def wait_for_anvil(rpc_url: str, timeout_s: float = 30.0) -> None:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            r = subprocess.run(
                ["cast", "block-number", "--rpc-url", rpc_url], capture_output=True, text=True, timeout=5
            )
            if r.returncode == 0:
                return
        except (subprocess.TimeoutExpired, OSError):
            pass
        time.sleep(0.2)
    raise RuntimeError(f"anvil at {rpc_url} did not become ready within {timeout_s}s")


def port_in_use(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex(("127.0.0.1", port)) == 0


def parse_address(stdout: str, label: str) -> str:
    m = re.search(rf"{label}\s+(0x[0-9a-fA-F]{{40}})", stdout)
    if not m:
        raise RuntimeError(f"no {label} line in:\n{stdout}")
    return m.group(1)


def fetch_jsonrpc(rpc_url: str, method: str, params: list[Any]) -> dict[str, Any]:
    data = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(
        rpc_url, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        body: dict[str, Any] = json.loads(resp.read())
    if "error" in body:
        raise RuntimeError(f"JSON-RPC {method} failed: {body['error']}")
    return body


def read_payouts_from_events(rpc_url: str, manifest: dict[str, Any], third_asset: str) -> dict[str, int]:
    """Compute the paid-out amount for the USDC (asset 0) and the third asset (asset 2) from the
    adjudicator's AllocationUpdated events.

    Each successful per-asset transfer emits AllocationUpdated(channelId, asset, initialHoldings,
    finalHoldings); the paid amount is initialHoldings - finalHoldings. The middle asset's refused
    transfer emits no event (it reverts before the emit), so only the first and third assets
    appear in the events.
    """
    usdc = manifest["armada"]["usdc"]
    adjudicator = manifest["armadaNitro"]["adjudicator"]

    latest = fetch_jsonrpc(rpc_url, "eth_blockNumber", [])["result"]
    logs = fetch_jsonrpc(
        rpc_url,
        "eth_getLogs",
        [
            {
                "address": [adjudicator],
                "topics": [ALLOC_UPDATED_TOPIC],
                "fromBlock": "0x1",
                "toBlock": latest,
            }
        ],
    )["result"]

    first_payout = 0
    third_payout = 0
    for entry in logs:
        # data = 96 bytes: asset (32-byte word, address right-aligned), initialHoldings (32 bytes),
        # finalHoldings (32 bytes).
        raw = entry["data"][2:]
        if len(raw) < 192:
            continue
        # asset: last 40 hex chars (20 bytes) of the first 32-byte word.
        asset_addr = "0x" + raw[24:64].lower()
        initial_holdings = int(raw[64:128], 16)
        final_holdings = int(raw[128:192], 16)
        payout = initial_holdings - final_holdings
        if asset_addr == usdc.lower():
            first_payout = payout
        elif asset_addr == third_asset.lower():
            third_payout = payout
    return {"first_asset_payout": first_payout, "third_asset_payout": third_payout}


def run_check(port: int) -> dict[str, int]:
    """Run the full three-asset fallback check on a fresh anvil node; returns
    {"first_asset_payout": int, "third_asset_payout": int}."""
    rpc_url = f"http://127.0.0.1:{port}"
    scratch = os.path.join(REPO_ROOT, "deployments", "31337-watchtower-fallback-check")
    shutil.rmtree(scratch, ignore_errors=True)
    os.makedirs(os.path.join(scratch, "keys"), exist_ok=True)

    if port_in_use(port):
        raise RuntimeError(f"port {port} already in use; set ANVIL_PORT_BASE to a free range")

    anvil_log = open(os.path.join(scratch, "anvil.log"), "w")
    anvil = subprocess.Popen(
        ["anvil", "--host", "127.0.0.1", "--port", str(port)],
        cwd=REPO_ROOT,
        stdout=anvil_log,
        stderr=subprocess.STDOUT,
    )
    try:
        wait_for_anvil(rpc_url)

        env = dict(os.environ)
        env.update(
            {
                "DEPLOYER_KEY": DEPLOYER_KEY,
                "USER_KEY": USER_KEY,
                "HUB_KEY": HUB_KEY,
                "CHALLENGE_DURATION": CHALLENGE_DURATION,
                "STATE_N_USER": STATE_N_USER,
                "STATE_N1_USER": STATE_N1_USER,
                "HUB_RESERVE": HUB_RESERVE,
                "SECOND_ASSET_AMOUNT": SECOND_ASSET_AMOUNT,
                "THIRD_ASSET_AMOUNT": THIRD_ASSET_AMOUNT,
                "MANIFEST_PATH": os.path.join(scratch, "manifest.json"),
                "DEPOSITS_PATH": os.path.join(scratch, "deposits.json"),
                "KEYS_DIR": os.path.join(scratch, "keys"),
            }
        )

        # 1. Deploy the three-asset channel; the middle asset's token is set to always-revert.
        setup_p = forge_script(
            "script/WatchtowerFallbackSetup.s.sol",
            "WatchtowerFallbackSetup",
            "setup(bool)",
            ["true"],
            True,
            rpc_url,
            env,
        )
        env["SECOND_ASSET"] = parse_address(setup_p.stdout, "SECOND_ASSET")
        third_asset = parse_address(setup_p.stdout, "THIRD_ASSET")
        env["THIRD_ASSET"] = third_asset

        # 2. The hub challenges the stale state N.
        forge_script(
            "script/WatchtowerScenario.s.sol",
            "WatchtowerScenario",
            "openAndChallenge(uint256)",
            ["0"],
            True,
            rpc_url,
            env,
        )

        # 3. The watchtower answers -- forces the per-asset fallback (middle asset's token refuses).
        forge_script(
            "script/WatchtowerScenario.s.sol",
            "WatchtowerScenario",
            "respond(uint256)",
            ["0"],
            True,
            rpc_url,
            env,
        )

        # 4. Read the per-asset payouts from the adjudicator's AllocationUpdated events.
        with open(env["MANIFEST_PATH"]) as f:
            manifest = json.load(f)
        return read_payouts_from_events(rpc_url, manifest, third_asset)
    finally:
        anvil.terminate()
        try:
            anvil.wait(timeout=10)
        except subprocess.TimeoutExpired:
            anvil.kill()
            anvil.wait(timeout=10)
        anvil_log.close()


def main() -> int:
    result = run_check(ANVIL_PORT_BASE)
    # spec_oracle: the runner json.loads the whole stdout; print the two payout fields.
    json.dump(result, sys.stdout)
    print()
    if (result["first_asset_payout"] <= 0) or (result["third_asset_payout"] <= 0):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
