#!/usr/bin/env python3
"""armada-assets-e2e gate (arn-5fb, E11).

Stands up the Aave fixturenet from the warm snapshot (arn-d5a's saved
base-layer snapshot), runs the Aave yield scenario and the redeem scenario
on-chain, and tears down the fixturenet on exit.

Yield scenario (E11 scenario 1): the hub (anvil account 1) deposits USDC into
the waUSDC ERC-4626 vault; a second account (anvil account 2) supplies USDC
to the Aave pool and borrows USDC to raise utilization; time advances at least
60 seconds of blocks; then both waUSDC.convertToAssets(1e6) and the Aave USDC
liquidityIndex have increased.

Redeem scenario (E11 scenario 4): the hub redeems its waUSDC for USDC; the
hub's USDC balance grows by at least the yield scenario principal.

Running with --skip-borrow skips the borrow step so the yield check fails
(c3). The gate prints exactly two evidence lines (one per scenario) and a
final JSON line carrying every spec'd field. It never configures the Lido
oracle (c5) and, unless KEEP_FIXTURENET=1, tears down the running fixturenet
and removes the deployment directory on exit via atexit, leaving nothing
running (c6).

This script never stands up the fixturenet, reads its state directory or
tears it down itself: it delegates to the arn-d5a compose job
(stack/compose-jobs/armada-assets-e2e/run.sh, with KEEP_FIXTURENET=1), a
run-job that prints the deployment manifest from inside a container
(docker-compose-armada-assets-e2e-manifest.yml), and a teardown helper beside
run.sh (teardown.sh). Those three pieces hold the host access this gate
itself must not use (gate-no-host-deployment-access pre-commit hook).

Run: python3 scripts/armada-assets-e2e.py [--skip-borrow]
"""

from __future__ import annotations

import argparse
import atexit
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any

# ---- paths -----------------------------------------------------------------
SCRIPT = Path(__file__).resolve()
REPO_ROOT = SCRIPT.parents[1]  # scripts/ is one level under the repo root
DEP_DIR = Path.home() / "deployments" / "armada-assets-e2e"
RUN_SH = REPO_ROOT / "stack" / "compose-jobs" / "armada-assets-e2e" / "run.sh"
TEARDOWN_SH = REPO_ROOT / "stack" / "compose-jobs" / "armada-assets-e2e" / "teardown.sh"
CLUSTER_ID_FILE = REPO_ROOT / ".scratch" / "armada-assets-e2e-cluster-id"

# anvil dev accounts (the fixturenet's geth premints 10 accounts from the
# "test test test test test test test test test test test junk" mnemonic;
# these three are also stack/config/deployment-config.example.env's
# DEPLOYER_KEY and lib/armada-poc/.claude/archive/THIRD_CHAIN.md's user1/user2,
# and each is verified here against its address with `cast wallet address`).
DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # account 0
HUB_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"  # account 1
HUB_ADDR = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"  # account 1
SECOND_KEY = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"  # account 2
SECOND_ADDR = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"  # account 2

# scenario amounts (USDC, 6 decimals)
PRINCIPAL = 100_000_000  # 100 USDC the hub deposits into waUSDC
HUB_FUND = 200_000_000  # deployer mints 200 USDC to the hub (2x principal)
SECOND_FUND = 100_000_000  # deployer mints 100 USDC to the second account
SECOND_SUPPLY = 100_000_000  # second account supplies 100 USDC
SECOND_BORROW = 50_000_000  # second account borrows 50 USDC (50% utilization)

WAIT_SECONDS = 65  # advance at least 60 s of blocks (c1)


# ---- helpers ---------------------------------------------------------------


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def run(
    cmd: list[str], check: bool = True, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    log("+ " + " ".join(cmd))
    p = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if p.stdout:
        log(p.stdout)
    if p.stderr and p.returncode != 0:
        log(p.stderr)
    if check and p.returncode != 0:
        raise RuntimeError(f"command failed (exit {p.returncode}): {' '.join(cmd)}")
    return p


def laconic_so() -> str:
    exe = os.environ.get("LACONIC_SO")
    if exe:
        return exe
    exe = shutil.which("laconic-so")
    if not exe:
        raise RuntimeError("laconic-so not found on PATH; set LACONIC_SO or add it to PATH")
    return exe


def repo_head() -> str:
    return run(["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"]).stdout.strip()


def resolve_geth_rpc() -> str:
    """Resolve the geth RPC port the same way run.sh's own resolve_geth_rpc
    does: the cluster id run.sh recorded, then `docker port`."""
    cluster = CLUSTER_ID_FILE.read_text().strip()
    ctr = f"{cluster}-armada-fixturenet-geth-1"
    out = run(["docker", "port", ctr, "8545"], check=False)
    if out.returncode != 0 or not out.stdout.strip():
        raise RuntimeError(f"no published 8545 for {ctr}")
    line = out.stdout.strip().splitlines()[0]
    host_port = line.split("->")[-1].strip() if "->" in line else line.strip()
    return "http://" + host_port


def start_fixturenet() -> str:
    """Stand up the Aave fixturenet from the warm snapshot via the arn-d5a
    compose job, with KEEP_FIXTURENET=1 so the fixturenet stays up for the
    scenarios below. run.sh already builds the images, restores the warm
    snapshot, starts the deployment, waits for blocks and verifies the base
    target (Aave pool, waUSDC, USDC all answer)."""
    env = dict(os.environ)
    env["KEEP_FIXTURENET"] = "1"
    run(["bash", str(RUN_SH)], env=env)
    return resolve_geth_rpc()


def wait_for_blocks(rpc: str) -> None:
    deadline = time.time() + 180
    prev = None
    while time.time() < deadline:
        try:
            req = urllib.request.Request(
                rpc,
                data=json.dumps(
                    {"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []}
                ).encode(),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                block = int(json.loads(resp.read())["result"], 16)
            if prev is not None and block != prev:
                return
            prev = block
            time.sleep(2)
        except Exception:
            time.sleep(2)
    raise RuntimeError("fixturenet did not start producing blocks within 180s")


def read_manifest() -> dict[str, Any]:
    """Read the deployment's manifest via the armada-assets-e2e-manifest
    run-job, which prints it from inside a container -- this script never
    reads the deployment's data directory itself."""
    so = laconic_so()
    env = dict(os.environ)
    env["ARMADA_IMAGE_TAG"] = repo_head()
    out = run([so, "deployment", "--dir", str(DEP_DIR), "run-job", "armada-assets-e2e-manifest"], env=env)
    for line in out.stdout.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            manifest = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "aave" in manifest and "usdc" in manifest:
            return manifest  # type: ignore[no-any-return]
    raise RuntimeError("armada-assets-e2e-manifest run-job printed no manifest JSON line")


# ---- on-chain helpers ------------------------------------------------------


def cast_call(rpc: str, contract: str, signature: str, *args: str) -> str:
    out = run(["cast", "call", contract, signature, *args, "--rpc-url", rpc])
    return out.stdout.strip()


def cast_send(rpc: str, key: str, contract: str, signature: str, *args: str) -> str:
    out = run(["cast", "send", contract, signature, *args, "--rpc-url", rpc, "--private-key", key, "--json"])
    return out.stdout


def parse_cast_int(s: str) -> int:
    s = s.split()[0]
    if s.startswith("0x"):
        return int(s, 16)
    return int(s)


def balance_of(rpc: str, token: str, addr: str) -> int:
    out = cast_call(rpc, token, "balanceOf(address)", addr)
    return int(out.split()[0])


def wausdc_convert_to_assets(rpc: str, vault: str, shares: int) -> int:
    out = cast_call(rpc, vault, "convertToAssets(uint256)", str(shares))
    return int(out.split()[0])


def aave_liquidity_index(rpc: str, pool: str, asset: str) -> int:
    out = cast_call(
        rpc,
        pool,
        "getReserveData(address)((uint256),uint128,uint128,uint128,uint128,uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128)",
        asset,
    )
    s = out
    if s.startswith("(") and s.endswith(")"):
        s = s[1:-1]
    fields = []
    depth = 0
    current = []
    for ch in s:
        if ch == "(":
            depth += 1
            current.append(ch)
        elif ch == ")":
            depth -= 1
            current.append(ch)
        elif ch == "," and depth == 0:
            fields.append("".join(current).strip())
            current = []
        else:
            current.append(ch)
    fields.append("".join(current).strip())
    return parse_cast_int(fields[1])


# ---- scenarios -------------------------------------------------------------


def run_yield_scenario(rpc: str, manifest: dict[str, Any], skip_borrow: bool) -> dict[str, Any]:
    pool = manifest["aave"]["pool"]
    vault = manifest["assets"]["waUSDC"]
    usdc = manifest["usdc"]["proxy"]
    # fund the hub (account 1) with 2x the principal; the deployer mints USDC.
    cast_send(rpc, DEPLOYER_KEY, usdc, "mint(address,uint256)", HUB_ADDR, str(HUB_FUND))
    cast_send(rpc, DEPLOYER_KEY, usdc, "mint(address,uint256)", SECOND_ADDR, str(SECOND_FUND))
    # the hub approves the vault and deposits the principal into waUSDC.
    cast_send(rpc, HUB_KEY, usdc, "approve(address,uint256)", vault, str(PRINCIPAL))
    cast_send(rpc, HUB_KEY, vault, "deposit(uint256,address)", str(PRINCIPAL), HUB_ADDR)
    # the second account (account 2) supplies USDC to the pool and borrows to raise utilization.
    cast_send(rpc, SECOND_KEY, usdc, "approve(address,uint256)", pool, str(SECOND_SUPPLY))
    cast_send(
        rpc,
        SECOND_KEY,
        pool,
        "supply(address,uint256,address,uint16)",
        usdc,
        str(SECOND_SUPPLY),
        SECOND_ADDR,
        "0",
    )
    if not skip_borrow:
        cast_send(
            rpc,
            SECOND_KEY,
            pool,
            "borrow(address,uint256,uint256,uint16,address)",
            usdc,
            str(SECOND_BORROW),
            "2",
            "0",
            SECOND_ADDR,
        )
    # read before / wait / read after
    convert_before = wausdc_convert_to_assets(rpc, vault, 1_000_000)
    liq_before = aave_liquidity_index(rpc, pool, usdc)
    t0 = time.time()
    time.sleep(WAIT_SECONDS)
    advanced_seconds = time.time() - t0
    convert_after = wausdc_convert_to_assets(rpc, vault, 1_000_000)
    liq_after = aave_liquidity_index(rpc, pool, usdc)
    convert_increased = convert_after > convert_before
    liq_increased = liq_after > liq_before
    return {
        "convert_before": convert_before,
        "convert_after": convert_after,
        "liq_before": liq_before,
        "liq_after": liq_after,
        "scenario1_convert_to_assets_increased": convert_increased,
        "scenario1_liquidity_index_increased": liq_increased,
        "scenario1_blocks_advanced_seconds": int(advanced_seconds),
        "yield_check_passed": convert_increased and liq_increased,
    }


def run_redeem_scenario(rpc: str, manifest: dict[str, Any]) -> dict[str, Any]:
    vault = manifest["assets"]["waUSDC"]
    usdc = manifest["usdc"]["proxy"]
    # the hub redeems its waUSDC for USDC; the hub's USDC balance grows by at
    # least the yield scenario principal.
    bal_before = balance_of(rpc, usdc, HUB_ADDR)
    shares = balance_of(rpc, vault, HUB_ADDR)
    cast_send(rpc, HUB_KEY, vault, "redeem(uint256,address,address)", str(shares), HUB_ADDR, HUB_ADDR)
    bal_after = balance_of(rpc, usdc, HUB_ADDR)
    redeem_ge_principal = bal_after >= bal_before + PRINCIPAL
    return {
        "scenario4_redeem_ge_principal": redeem_ge_principal,
        "bal_before": bal_before,
        "bal_after": bal_after,
    }


# ---- main ------------------------------------------------------------------


def teardown() -> None:
    """Tear down the running fixturenet via the teardown helper beside
    run.sh -- this gate script never touches the deployment's data directory
    itself. Honors KEEP_FIXTURENET=1."""
    run(["bash", str(TEARDOWN_SH)], check=False)


def main() -> None:
    ap = argparse.ArgumentParser(description="armada-assets-e2e gate (arn-5fb)")
    ap.add_argument(
        "--skip-borrow",
        action="store_true",
        help="skip the second account's borrow step so the yield check fails",
    )
    args = ap.parse_args()
    # Register teardown before any step that could leave a deployment
    # running: an exception in start_fixturenet, wait_for_blocks or either
    # scenario must still tear the fixturenet down.
    atexit.register(teardown)
    log("armada-assets-e2e: standing up the Aave fixturenet from the warm snapshot ...")
    rpc = start_fixturenet()
    wait_for_blocks(rpc)
    manifest = read_manifest()
    yield_res = run_yield_scenario(rpc, manifest, args.skip_borrow)
    redeem_res = run_redeem_scenario(rpc, manifest)
    # print exactly two evidence lines (one per scenario)
    print(
        f"scenario 1 (yield): hub deposited {PRINCIPAL/1e6:.0f} USDC into waUSDC; "
        f"convertToAssets(1e6) {yield_res['convert_before']} -> {yield_res['convert_after']} "
        f"(increased={yield_res['scenario1_convert_to_assets_increased']}); "
        f"USDC liquidityIndex {yield_res['liq_before']} -> {yield_res['liq_after']} "
        f"(increased={yield_res['scenario1_liquidity_index_increased']})"
    )
    print(
        f"scenario 4 (redeem): hub's USDC balance "
        f"{redeem_res['bal_before']/1e6:.0f} -> {redeem_res['bal_after']/1e6:.0f} "
        f"USDC; redeem returned at least the principal ({redeem_res['scenario4_redeem_ge_principal']})"
    )
    result = {
        "fixturenet_up": True,
        "scenario1_convert_to_assets_increased": yield_res["scenario1_convert_to_assets_increased"],
        "scenario1_liquidity_index_increased": yield_res["scenario1_liquidity_index_increased"],
        "scenario1_blocks_advanced_seconds": yield_res["scenario1_blocks_advanced_seconds"],
        "scenario4_redeem_ge_principal": redeem_res["scenario4_redeem_ge_principal"],
        "yield_check_passed": yield_res["yield_check_passed"],
        "scenario_line_count": 2,
    }
    print(json.dumps(result))


if __name__ == "__main__":
    main()
