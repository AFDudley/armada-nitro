#!/usr/bin/env python3
"""Settle-stale per-asset check (arn-16a): after a challenged two-asset channel's challenge
window elapses, settling it must still pay the first asset the same non-zero amount whether or
not the second asset's token reverts on transfer (design 15 invariant I5; E16 deliverable S4).

Runs entirely against a fresh, local anvil node (never the shared fixturenet). Each run below:

  1. starts anvil and deploys a fresh Armada pool + ArmadaNitroAdjudicator + ConsensusApp
     (script/WatchtowerPerAssetSetup.s.sol's `setup(bool)` -- asset 0 = real USDC, asset 1 =
     a ToggleableERC20 whose transfers this run's `setup(bool)` argument either leaves working
     or switches to always-revert);
  2. funds the channel and has the hub challenge it with the stale, co-signed state N
     (script/WatchtowerScenario.s.sol's `openAndChallenge(uint256)`, unmodified);
  3. advances the clock past CHALLENGE_DURATION (cast rpc evm_increaseTime + evm_mine) so the
     stale challenge settles;
  4. settles it (script/WatchtowerScenario.s.sol's `settleStale(uint256)` -- the function under
     test: it tries `transferAllAssets` first, and falls back to a per-asset
     `transfer(assetIndex: 0, ...)` only if that would revert);
  5. reads the first asset's paid amount (script/WatchtowerScenario.s.sol's `payoutSince(uint256)`,
     unmodified -- a `PAYOUT_LAMPORTS <value>` line, parsed the same way the armada-watchtower-
     e2e job parses it).

The `run <bool>` subcommand runs a single arm and exits 0 with the first-asset payout on the
`payout` field of the printed JSON (spec arn-16a c1). The `compare` subcommand runs both arms
(the normal arm, and the reverting arm) and exits 0 only when both arms' first-asset payouts are
equal and non-zero; it prints the metamorphic flows JSON either way:
{"flows": [normal, -reverting, 0]}, whose conservation relation (|sum(flows)| <= 1e-9) holds
exactly when the first asset's paid amount is invariant across the two arms (sum = normal -
reverting). The non-zero requirement is enforced by the exit code, not the JSON.

Environment: ANVIL_PORT_BASE (default 8646; the second arm uses ANVIL_PORT_BASE+1, so a stray
process holding one port doesn't wedge the whole check).
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

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANVIL_PORT_BASE = int(os.environ.get("ANVIL_PORT_BASE", "8646"))

# anvil/hardhat's published, widely-documented dev mnemonic ("test test ... junk") accounts 0-2
# -- the same keys docs/ENVIRONMENT.md and env/reconciler/modules/_wallet.py derive from for
# every other local-anvil fixture in this repo.
DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
USER_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
HUB_KEY = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"

CHALLENGE_DURATION = "5"
STATE_N_USER = "1000000"
STATE_N1_USER = "2000000"
HUB_RESERVE = "500000"
SECOND_ASSET_AMOUNT = "300000"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def run(cmd: list[str], env: dict[str, str]) -> "subprocess.CompletedProcess[str]":
    log("+ " + " ".join(cmd))
    p = subprocess.run(cmd, cwd=REPO_ROOT, env=env, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"command failed (exit {p.returncode}): {' '.join(cmd)}\n{p.stdout}\n{p.stderr}")
    return p


def forge_script(
    script: str, sig: str, args: list[str], broadcast: bool, rpc_url: str, env: dict[str, str]
) -> "subprocess.CompletedProcess[str]":
    cmd = ["forge", "script", script, "--sig", sig, *args]
    if broadcast:
        cmd.append("--broadcast")
    cmd += ["--rpc-url", rpc_url]
    return run(cmd, env)


def cast_rpc(rpc_url: str, method: str, *args: str) -> None:
    run(
        ["cast", "rpc", method, *args, "--rpc-url", rpc_url],
        dict(os.environ),
    )


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


def parse_payout(stdout: str) -> int:
    m = re.search(r"PAYOUT_LAMPORTS\s+(\d+)", stdout)
    if not m:
        raise RuntimeError(f"no PAYOUT_LAMPORTS line in:\n{stdout}")
    return int(m.group(1))


def run_once(second_asset_reverts: bool, port: int) -> int:
    """Fresh anvil + fresh two-asset channel; settles after the challenge window; returns the
    first asset's paid amount."""
    label = "reverting" if second_asset_reverts else "normal"
    rpc_url = f"http://127.0.0.1:{port}"
    scratch = os.path.join(REPO_ROOT, "deployments", f"31337-watchtower-settle-stale-check-{label}")
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
                "MANIFEST_PATH": os.path.join(scratch, "manifest.json"),
                "DEPOSITS_PATH": os.path.join(scratch, "deposits.json"),
                "KEYS_DIR": os.path.join(scratch, "keys"),
            }
        )

        setup_p = forge_script(
            "script/WatchtowerPerAssetSetup.s.sol",
            "setup(bool)",
            [str(second_asset_reverts).lower()],
            True,
            rpc_url,
            env,
        )
        env["SECOND_ASSET"] = parse_address(setup_p.stdout, "SECOND_ASSET")

        forge_script(
            "script/WatchtowerScenario.s.sol", "openAndChallenge(uint256)", ["0"], True, rpc_url, env
        )
        # Let the challenge window elapse so the stale challenge settles (scenario B).
        cast_rpc(rpc_url, "evm_increaseTime", str(int(CHALLENGE_DURATION) + 1))
        cast_rpc(rpc_url, "evm_mine")

        forge_script("script/WatchtowerScenario.s.sol", "settleStale(uint256)", ["0"], True, rpc_url, env)
        payout_p = forge_script(
            "script/WatchtowerScenario.s.sol", "payoutSince(uint256)", ["0"], False, rpc_url, env
        )
        return parse_payout(payout_p.stdout)
    finally:
        anvil.terminate()
        try:
            anvil.wait(timeout=10)
        except subprocess.TimeoutExpired:
            anvil.kill()
            anvil.wait(timeout=10)
        anvil_log.close()


def run_arm(argv: list[str]) -> int:
    """`run <bool>`: run one arm, print {"payout": value}, exit 0 (spec c1)."""
    second_asset_reverts = argv[1].lower() in ("true", "1")
    payout = run_once(second_asset_reverts, ANVIL_PORT_BASE)
    json.dump({"payout": payout}, sys.stdout)
    print()
    if payout <= 0:
        return 1
    return 0


def compare_arms() -> int:
    """`compare`: run both arms, print the flows JSON, exit 0 when the first asset's payout is
    invariant and non-zero (spec c2)."""
    normal_payout = run_once(False, ANVIL_PORT_BASE)
    reverting_payout = run_once(True, ANVIL_PORT_BASE + 1)

    result = {"flows": [normal_payout, -reverting_payout, 0]}
    json.dump(result, sys.stdout)
    print()

    if normal_payout == 0 or reverting_payout == 0:
        return 1
    return 0 if normal_payout == reverting_payout else 1


def main() -> int:
    argv = sys.argv[1:]
    if len(argv) >= 1 and argv[0] == "run":
        return run_arm(argv)
    elif len(argv) >= 1 and argv[0] == "compare":
        return compare_arms()
    else:
        print(__doc__, file=sys.stderr)
        print(f"usage: {sys.argv[0]} [run <bool>|compare]", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
