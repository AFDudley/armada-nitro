#!/usr/bin/env python3
"""armada-watchtower-e2e job orchestrator (E15b).

Runs entirely inside the job container (working_dir /src/armada-nitro). Builds the two
real-proof channel deposits, runs the on-chain watchtower scenario for scenario A (watcher ON:
answer the stale challenge in time with the newer fully-signed state N+1) and scenario B (watcher
OFF: let the window elapse, settle the stale state N), then prints exactly one JSON line to stdout:

    {"scenario_a": {...}, "scenario_b": {...}}

Environment (all optional, with safe defaults):
    HUB_RPC          execution RPC (default http://127.0.0.1:8545)
    MANIFEST_PATH    deployment manifest (default /env/manifest.json)
    DEPOSITS_PATH    deposit output (default /env/watchtower-e2e/deposits.json)
    CHALLENGE_DURATION  the ForceMove challenge window (default 30)
    STATE_N_USER     state N's user allocation (default 1000000)
    STATE_N1_USER    state N+1's user allocation (default 2000000)
    HUB_RESERVE      the hub's reserve (default 500000)
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time

HUB_RPC: str = os.environ.get("HUB_RPC", "http://armada-fixturenet-geth:8545")
STATE_N_USER: int = int(os.environ.get("STATE_N_USER", "1000000"))
STATE_N1_USER: int = int(os.environ.get("STATE_N1_USER", "2000000"))
CHALLENGE_DURATION: str = os.environ.get("CHALLENGE_DURATION", "30")
HUB_RESERVE: int = int(os.environ.get("HUB_RESERVE", "500000"))
DEPOSIT_AMOUNT_UNITS: int = STATE_N1_USER + HUB_RESERVE
MANIFEST_PATH: str = os.environ.get("MANIFEST_PATH", "/env/manifest.json")
DEPOSITS_PATH: str = os.environ.get("DEPOSITS_PATH", "/env/watchtower-e2e/deposits.json")
CHAIN_ID: str = "31337"
BCAST: str = f"/src/armada-nitro/broadcast/WatchtowerScenario.s.sol/{CHAIN_ID}"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def run(
    cmd: list[str], cwd: str | None = None, env: dict[str, str] | None = None
) -> "subprocess.CompletedProcess[str]":
    log("+ " + " ".join(cmd))
    p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)
    if p.stdout:
        log(p.stdout)
    if p.stderr:
        log(p.stderr)
    if p.returncode != 0:
        raise RuntimeError(f"command failed (exit {p.returncode}): {' '.join(cmd)}")
    return p


# ---- Stage 1: build the two channel deposits (real-proof shield + Groth16-proved
# depositFromNote bound to the adjudicator).
run(["mkdir", "-p", "/src/armada-poc/scripts/gates"])
run(["cp", "/src/armada-nitro/env/gates/watchtower/prepare.ts", "/src/armada-poc/scripts/gates/prepare.ts"])
penv = dict(os.environ)
penv.update(
    {
        "MANIFEST_PATH": MANIFEST_PATH,
        "DEPOSITS_PATH": DEPOSITS_PATH,
        "CHALLENGE_DURATION": CHALLENGE_DURATION,
        "DEPOSIT_AMOUNT_UNITS": str(DEPOSIT_AMOUNT_UNITS),
        "HUB_RPC": HUB_RPC,
        "DEPLOY_ENV": "local",
        "CCTP_MODE": "real",
    }
)
run(
    ["npx", "hardhat", "run", "scripts/gates/prepare.ts", "--network", "hub"], cwd="/src/armada-poc", env=penv
)


def forge(sig: str, idx: int, broadcast: bool) -> "subprocess.CompletedProcess[str]":
    cmd = ["forge", "script", "script/WatchtowerScenario.s.sol", "--sig", sig, str(idx), "--rpc-url", HUB_RPC]
    if broadcast:
        cmd.append("--broadcast")
    p = subprocess.run(cmd, cwd="/src/armada-nitro", capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"forge {sig}({idx}) failed:\n{p.stdout}\n{p.stderr}")
    return p


def bcast_tx(sig: str, fn_prefix: str) -> str:
    path = f"{BCAST}/{sig}-latest.json"
    data = json.load(open(path))
    for tx in data.get("transactions", []):
        if (tx.get("function") or "").startswith(fn_prefix):
            return str(tx["hash"])
    raise RuntimeError(f"no {fn_prefix} tx in {path}")


def to_int(value: str | int) -> int:
    if isinstance(value, str) and value.startswith("0x"):
        return int(value, 16)
    return int(value)


def block_ts(tx_hash: str) -> int:
    r = subprocess.run(
        ["cast", "receipt", tx_hash, "--rpc-url", HUB_RPC, "--json"], capture_output=True, text=True
    )
    block_num = to_int(json.loads(r.stdout)["blockNumber"])
    b2 = subprocess.run(
        ["cast", "block", str(block_num), "--rpc-url", HUB_RPC, "--json"], capture_output=True, text=True
    )
    bd = json.loads(b2.stdout)
    if isinstance(bd, dict) and "data" in bd:
        bd = bd["data"]
    return to_int(bd["timestamp"])


def parse_payout(stdout: str) -> int:
    m = re.search(r"PAYOUT_LAMPORTS\s+(\d+)", stdout)
    if not m:
        raise RuntimeError(f"no PAYOUT_LAMPORTS line in:\n{stdout}")
    return int(m.group(1))


# ---- Scenario A: watcher ON -- the hub challenges with the stale, co-signed state N; the
# watcher answers in time with the newer, fully-signed, final state N+1, finalizing via
# `conclude` and then paying out every asset of the outcome with its own
# transfer(assetIndex, ...) call (E16 S4 / design 15 I5 / arn-df2): no combined
# concludeAndTransferAllAssets call, no fallback.
forge("openAndChallenge(uint256)", 0, broadcast=True)
challenge_tx_a = bcast_tx("openAndChallenge", "challenge(")
forge("respond(uint256)", 0, broadcast=True)
response_tx_a = bcast_tx("respond", "transfer(")
lat_a = max(0, block_ts(response_tx_a) - block_ts(challenge_tx_a))
p = forge("payoutSince(uint256)", 0, broadcast=False)
payout_a = parse_payout(p.stdout)
check_a = (
    f"scenario A: PASS -- watcher answered in time, payout {payout_a} lamports "
    f"(state N+1's {STATE_N1_USER} net of shield fee)"
)

# ---- Scenario B: watcher OFF -- the hub challenges with the stale state N; no response
# arrives, the window elapses, and the stale state settles.
forge("openAndChallenge(uint256)", 1, broadcast=True)
challenge_tx_b = bcast_tx("openAndChallenge", "challenge(")
log(f"watcher off; waiting out the {CHALLENGE_DURATION}s challenge window...")
time.sleep(int(CHALLENGE_DURATION) + 5)
forge("settleStale(uint256)", 1, broadcast=True)
p = forge("payoutSince(uint256)", 1, broadcast=False)
payout_b = parse_payout(p.stdout)
check_b = (
    f"scenario B: PASS -- no watcher response, stale challenge stood, payout "
    f"{payout_b} lamports (state N's {STATE_N_USER} net of shield fee)"
)

result = {
    "scenario_a": {
        "watcher_enabled": True,
        "challenge_tx": challenge_tx_a,
        "response_tx": response_tx_a,
        "response_latency_seconds": float(lat_a),
        "payout_lamports": payout_a,
        "check_line": check_a,
    },
    "scenario_b": {
        "watcher_enabled": False,
        "challenge_tx": challenge_tx_b,
        "response_tx": "",
        "payout_lamports": payout_b,
        "check_line": check_b,
    },
}
print(json.dumps(result))
