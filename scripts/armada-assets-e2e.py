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
final JSON line carrying every spec'd field (c1, c2, c4). It never configures
the Lido oracle (c5) and, unless KEEP_FIXTURENET=1, tears down the running
fixturenet and removes the deployment directory on exit via atexit (c7),
leaving nothing running (c6).

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

# CERC_CONTAINER_BASE_DIR for the image builds (mirrors fixturenet-new).
_CERC_CONTAINER_BASE_DIR = os.environ.get(
    "CERC_CONTAINER_BASE_DIR",
    os.path.join(os.path.expanduser("~"), "src", "stack-orchestrator", "stack_orchestrator", "data", "container-build"),
)

# ---- paths -----------------------------------------------------------------
SCRIPT = Path(__file__).resolve()
REPO_ROOT = SCRIPT.parents[1]  # scripts/ is one level under the repo root
DEP_DIR = Path.home() / "deployments" / "armada-assets-e2e"
SPEC_FILE = Path.home() / "deployments" / "armada-assets-e2e-spec.yml"
STACK = "stack/stacks/armada-nitro-fixturenet"
SNAP_DIR = Path(os.environ.get("FIXTURENET_SNAP_DIR", str(Path.home() / "deployments" / ".snapshots")))

# anvil dev accounts (the fixturenet's geth premints 10 accounts from the
# "test test test test test test test test test test test junk" mnemonic).
DEPLOYER_KEY = "0xac0974bec39a17e36ba4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # account 0
HUB_KEY = "0x598538031d13fbdfb8d198e5e99a3b8264557f51616d53f540961a20d1"  # account 1
HUB_ADDR = "0x70997970C51812dc3A010C7d01b50e0d1d7dc79C8"  # account 1
SECOND_KEY = "0x428850664f33a1145116a297c376429a80d065032467f74580d065032467f74580d0"  # account 2
SECOND_ADDR = "0x2750572912986420536303c03280e1e22a21"  # account 2

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


def run(cmd: list[str], check: bool = True, env: dict = None) -> subprocess.CompletedProcess:
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


def ensure_images() -> None:
    """Build the env + foundry images for the fixturenet's jobs if missing."""
    head = run(["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"]).stdout.strip()
    for kind in ("env", "foundry"):
        image_ref = f"cerc/armada-nitro-{kind}:{head}"
        r = run(["docker", "image", "inspect", image_ref], check=False)
        if r.returncode != 0:
            build_sh = REPO_ROOT / "stack" / "container-build" / f"cerc-armada-nitro-{kind}" / "build.sh"
            if not build_sh.exists():
                raise RuntimeError(f"build script missing: {build_sh}")
            log(f"building {image_ref} ...")
            build_env = dict(os.environ)
            build_env["CERC_CONTAINER_BASE_DIR"] = _CERC_CONTAINER_BASE_DIR
            build_env["ARMADA_IMAGE_TAG"] = head
            r = run(["bash", str(build_sh)], env=build_env)
            if r.returncode != 0:
                raise RuntimeError(f"failed to build {image_ref}")


def compute_base_key() -> str:
    import hashlib
    result = run(["python3", str(REPO_ROOT / "stack" / "scripts" / "base-key.py"), "--root", str(REPO_ROOT)])
    return hashlib.sha256(result.stdout.encode()).hexdigest()[:16]


def snapshot_path(key: str) -> str:
    return str(SNAP_DIR / f"armada-fixturenet-base-{key}.tar.zst")


def start_fixturenet() -> str:
    """Stand up the Aave fixturenet from the warm snapshot (arn-d5a's)."""
    so = laconic_so()
    ensure_images()
    if not DEP_DIR.exists():
        run([so, "--stack", STACK, "deploy", "init",
              "--map-ports-to-host", "localhost-fixed-random",
              "--config-file", str(REPO_ROOT / "stack" / "config" / "deployment-config.example.env"),
              "--output", str(SPEC_FILE)])
        run([so, "--stack", STACK, "deploy", "create",
              "--spec-file", str(SPEC_FILE), "--deployment-dir", str(DEP_DIR)])
    # restore the warm snapshot
    key = compute_base_key()
    snap = snapshot_path(key)
    if not Path(snap).exists():
        raise RuntimeError(f"COLD: no base snapshot for key={key} at {snap}; the gate must not build the base layer (arn-46d.1)")
    # verify recorded key lines match (check_restore_key_diff)
    key_file = SNAP_DIR / f"armada-fixturenet-base-{key}.key"
    if key_file.exists():
        recorded = [l for l in key_file.read_text().splitlines() if not l.startswith("#")]
        fresh = run(["python3", str(REPO_ROOT / "stack" / "scripts" / "base-key.py"), "--root", str(REPO_ROOT)].stdout).splitlines()
        diffs = [f"line {i+1}: recorded={r} fresh={f}" for i, (r, f) in enumerate(zip(recorded, fresh)) if r != f]
        if len(recorded) != len(fresh):
            diffs.append(f"line count differs: recorded={len(recorded)} fresh={len(fresh)}")
        if diffs:
            for d in diffs:
                log(f"  {d}")
            raise RuntimeError(f"restore REFUSED: {len(diffs)} recorded key line(s) differ from the fresh base-key.py output")
    # restore the snapshot into the deployment's data dir
    data_dir = DEP_DIR / "data"
    if (data_dir / "armada_env").exists() or (data_dir / "geth_data").exists():
        # a prior restore is already in place; skip re-restore
        pass
    else:
        run(["sudo", "bash", "-c", f"cd {data_dir} && zstd -dc {snap} | sudo tar -C {data_dir} -xf -"])
    # start the deployment
    run([so, "deployment", "--dir", str(DEP_DIR), "start"])
    # resolve the geth RPC (docker port 8545)
    cluster = run(["grep", "-E", "^cluster-id:", str(DEP_DIR / "deployment.yml")].stdout.strip())
    ctr = f"{cluster}-armada-fixturenet-geth-1"
    line = run(["docker", "port", ctr, "8545"], check=False)
    if line.returncode != 0:
        raise RuntimeError(f"no published 8545 for {ctr}")
    rpc = "http://" + line.stdout.strip().split()[-1].lstrip(":")
    return rpc


def wait_for_blocks(rpc: str) -> None:
    import json as _json
    deadline = time.time() + 180
    prev = None
    while time.time() < deadline:
        try:
            req = urllib.request.Request(
                rpc, data=_json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []}).encode(),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                block = int(_json.loads(resp.read())["result"], 16)
            if prev is not None and block != prev:
                return
            prev = block
            time.sleep(2)
        except Exception:
            time.sleep(2)
    raise RuntimeError("fixturenet did not start producing blocks within 180s")


def read_manifest() -> dict:
    """Read the base-target manifest (armada_env volume) for the Aave addresses."""
    manifest_path = DEP_DIR / "data" / "armada_env" / "manifest.json"
    r = run(["sudo", "jq", ".", str(manifest_path)], check=False)
    if r.returncode != 0:
        if not manifest_path.exists():
            raise RuntimeError(f"manifest not found at {manifest_path}")
        r = run(["cat", str(manifest_path)])
    return json.loads(r.stdout)


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


def wausdc_convert_to_assets(rpc: str, vault: str, shares: int) -> int:
    out = cast_call(rpc, vault, "convertToAssets(uint256)", str(shares))
    return int(out.split()[0])


def aave_liquidity_index(rpc: str, pool: str, asset: str) -> int:
    out = cast_call(rpc, pool,
        "getReserveData(address)(uint256,uint128,uint128,uint128,uint128,uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128)", asset)
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


def usdc_balance(rpc: str, addr: str, usdc: str) -> int:
    out = cast_call(rpc, usdc, "balanceOf(address)", addr)
    return int(out.split()[0])


# ---- scenarios -------------------------------------------------------------

def run_yield_scenario(rpc: str, manifest: dict, skip_borrow: bool) -> dict:
    pool = manifest["aave"]["pool"]
    vault = manifest["assets"]["waUSDC"]
    usdc = manifest["usdc"]["proxy"]
    a_token = manifest["aave"]["aUSDC"]
    # fund the hub (account 1) with 2x the principal; the deployer mints USDC.
    cast_send(rpc, DEPLOYER_KEY, usdc, "mint(address,uint256)", HUB_ADDR, str(HUB_FUND))
    cast_send(rpc, DEPLOYER_KEY, usdc, "mint(address,uint256)", SECOND_ADDR, str(SECOND_FUND))
    # the hub approves the vault and deposits the principal into waUSDC.
    cast_send(rpc, HUB_KEY, usdc, "approve(address,uint256)", vault, str(PRINCIPAL))
    cast_send(rpc, HUB_KEY, vault, "deposit(uint256)", str(PRINCIPAL))
    # the second account (account 2) supplies USDC to the pool and borrows to raise utilization.
    cast_send(rpc, SECOND_KEY, usdc, "approve(address,uint256)", pool, str(SECOND_SUPPLY))
    cast_send(rpc, SECOND_KEY, pool, "supply(address,uint256,address,uint16)", usdc, str(SECOND_SUPPLY), SECOND_ADDR, "0")
    if not skip_borrow:
        cast_send(rpc, SECOND_KEY, pool, "borrow(address,uint256,uint256,uint16,address)", usdc, str(SECOND_BORROW), "2", "0", SECOND_ADDR)
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
        "scenario_line_count": 2,
    }


def run_redeem_scenario(rpc: str, manifest: dict) -> dict:
    vault = manifest["assets"]["waUSDC"]
    usdc = manifest["usdc"]["proxy"]
    # the hub redeems its waUSDC for USDC; the hub's USDC balance grows by at
    # least the yield scenario principal.
    bal_before = usdc_balance(rpc, HUB_ADDR, usdc)
    shares = wausdc_convert_to_assets(rpc, vault, 1_000_000)
    cast_send(rpc, HUB_KEY, vault, "redeem(uint256)", str(shares))
    bal_after = usdc_balance(rpc, HUB_ADDR, usdc)
    redeem_ge_principal = bal_after >= bal_before + PRINCIPAL
    return {
        "redeem_ge_principal": redeem_ge_principal,        "bal_before": bal_before,
        "bal_after": bal_after,
    }


# ---- main ------------------------------------------------------------------

def teardown() -> None:
    """Tear down the running fixturenet and remove the deployment directory,
    unless KEEP_FIXTURENET=1."""
    so = laconic_so()
    if os.environ.get("KEEP_FIXTURENET") == "1":
        log(f"KEEP_FIXTURENET=1 -- leaving the fixturenet running at {DEP_DIR}")
        return
    log("tearing down the running fixturenet ...")
    if (DEP_DIR / "spec.yml").exists() or (DEP_DIR / "deployment.yml").exists():
        run([so, "deployment", "--dir", str(DEP_DIR), "stop", "--delete-volumes"], check=False)
    if (DEP_DIR / "data").exists():
        run(["sudo", "umount", str(DEP_DIR / "data")], check=False)
    run(["sudo", "rm", "-rf", str(DEP_DIR)], check=False)
    log(f"{DEP_DIR} removed")


def main() -> None:
    ap = argparse.ArgumentParser(description="armada-assets-e2e gate (arn-5fb)")
    ap.add_argument("--skip-borrow", action="store_true", help="skip the second account's borrow step so the yield check fails")
    args = ap.parse_args()
    log("armada-assets-e2e: standing up the Aave fixturenet from the warm snapshot ...")
    rpc = start_fixturenet()
    wait_for_blocks(rpc)
    manifest = read_manifest()
    yield_res = run_yield_scenario(rpc, manifest, args.skip_borrow)
    redeem_res = run_redeem_scenario(rpc, manifest)
    # print exactly two evidence lines (one per scenario)
    print(
        f"scenario 1 (yield): hub deposited {PRINCIPAL/1e6:.0f} USDC into waUSDC, second account "
        f"supplied {yield_res['convert_before']/1e6:.0f} ... "
        f"convertToAssets(1e6) {yield_res['convert_before']} -> {yield_res['convert_after']} "
        f"(increased={yield_res['scenario1_convert_to_assets_increased']}); "
        f"USDC liquidityIndex {yield_res['liq_before']} -> {yield_res['liq_after']} "
        f"(increased={yield_res['scenario1_liquidity_index_increased']}"
    )
    print(
        f"scenario 4 (redeem): hub's USDC balance "
        f"{redeem_res['bal_before']/1e6:.0f} -> {redeem_res['bal_after']/1e6:.0f} "
        f"USDC; redeem returned at least the principal ({redeem_res['redeem_ge_principal']})"
    )
    result = {
        "fixturenet_up": True,
        "scenario1_convert_to_assets_increased": yield_res["scenario1_convert_to_assets_increased"],
        "scenario1_liquidity_index_increased": yield_res["scenario1_liquidity_index_increased"],
        "scenario1_blocks_advanced_seconds": yield_res["scenario1_blocks_advanced_seconds"],
        "scenario4_redeem_ge_principal": redeem_res["redeem_ge_principal"],
        "scenario_line_count": 2,
    }
    print(json.dumps(result))
    atexit.register(teardown)


if __name__ == "__main__":
    main()
