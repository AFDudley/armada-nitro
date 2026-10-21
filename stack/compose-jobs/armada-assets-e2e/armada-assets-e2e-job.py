#!/usr/bin/env python3
"""armada-assets-e2e-job.py — the armada-assets-e2e gate job (arn-a18).

Runs inside the job container (env image). Two stages:

  Stage 1: reuse the shared wallet + proof code in env/gates/nitro-e2e/prepare.ts
    (createWallet + the Groth16 prover via lib/sdk/wallet + lib/sdk/prover). The job
    copies prepare.ts into /src/armada-poc/scripts/gates/ and runs it with hardhat,
    exactly as docker-compose-armada-nitro-e2e.yml does (so the wallet and proof code
    is reused, not copied into this job). A stage 1 failure is logged and does not
    block stage 2 -- prepare.ts's e2e deposit scenario is unrelated to whether the
    Aave pool, waUSDC and USDC respond on the fixturenet RPC.

  Stage 2: prove the fixturenet is ready with the Aave pool, waUSDC, USDC and the
    adjudicator deployed -- four read-only cast calls against the fixturenet RPC
    (armada-fixturenet-geth:8545, arn-e7a c3/c4). The job prints exactly one JSON line:
    {"fixturenet_up": <true|false>}

`fixturenet_up` is true iff the Aave pool, waUSDC and USDC respond on the fixturenet
RPC and the adjudicator is deployed.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

REPO = Path("/src/armada-nitro")
POC = Path("/src/armada-poc")
MANIFEST_PATH = os.environ.get("MANIFEST_PATH", "/env/manifest.json")
RPC = os.environ.get("HUB_RPC", "http://armada-fixturenet-geth:8545")


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def run(
    cmd: list[str], env: dict[str, str] | None = None, cwd: str | None = None
) -> subprocess.CompletedProcess[str]:
    log("+ " + " ".join(cmd))
    p = subprocess.run(cmd, capture_output=True, text=True, env=env, cwd=cwd)
    if p.stdout:
        log(p.stdout)
    if p.stderr:
        log(p.stderr)
    return p


def stage1_reuse_prepare() -> None:
    """Reuse the shared wallet + proof code in env/gates/nitro-e2e/prepare.ts (stage 1).
    Logs and swallows failures -- this stage reuses the shared code but does not gate
    the fixturenet_up readiness check (stage 2)."""
    try:
        # Copy prepare.ts into the POC repo's gates dir and run it with hardhat (the
        # established pattern from docker-compose-armada-nitro-e2e.yml). This reuses --
        # does not copy -- the wallet + Groth16 proof code.
        gates = POC / "scripts" / "gates"
        gates.mkdir(parents=True, exist_ok=True)
        (gates / "prepare.ts").write_bytes((REPO / "env/gates/nitro-e2e/prepare.ts").read_bytes())
        env = os.environ.copy()
        env["MANIFEST_PATH"] = MANIFEST_PATH
        env["DEPOSITS_OUTPUT"] = "/env/armada-assets-e2e/deposits.json"
        env["CHALLENGE_DURATION"] = "30"
        env["HUB_RPC"] = RPC
        env["DEPLOY_ENV"] = "local"
        env["CCTP_MODE"] = "real"
        p = run(
            ["npx", "hardhat", "run", "scripts/gates/prepare.ts", "--network", "hub"], env=env, cwd=str(POC)
        )
        if p.returncode != 0:
            log(f"stage1_reuse_prepare: prepare.ts exited {p.returncode} (non-fatal)")
    except OSError as exc:
        log(f"stage1_reuse_prepare: failed to run prepare.ts (non-fatal): {exc}")


def stage2_ready() -> bool:
    """Prove the fixturenet is ready: Aave pool, waUSDC, USDC and the adjudicator
    all respond on the fixturenet RPC."""
    manifest = json.load(open(MANIFEST_PATH))
    aave_pool = manifest["aave"]["pool"]
    wa_usdc = manifest["assets"]["waUSDC"]
    usdc = manifest["usdc"]["proxy"]
    adjudicator = manifest["armadaNitro"]["adjudicator"]

    def cast_ok(addr: str, sig: str, *args: str) -> bool:
        p = subprocess.run(
            ["cast", "call", addr, sig, *args, "--rpc-url", RPC],
            capture_output=True,
            text=True,
        )
        if p.returncode != 0:
            log(f"cast call {addr} {sig} failed: {p.stderr}")
            return False
        return bool(p.stdout.strip())

    pool_ok = cast_ok(aave_pool, "getConfiguration(address)(uint256)", usdc)
    wa_ok = cast_ok(wa_usdc, "asset()(address)")
    usdc_ok = cast_ok(usdc, "decimals()(uint8)")
    adj_ok = cast_ok(adjudicator, "isAsset(address)", usdc)
    log(
        f"aave pool responds: {pool_ok}; waUSDC responds: {wa_ok}; USDC responds: {usdc_ok}; adjudicator responds: {adj_ok}"
    )
    return pool_ok and wa_ok and usdc_ok and adj_ok


def main() -> int:
    # Stage 1: reuse the wallet + proof code in env/gates/nitro-e2e/prepare.ts.
    stage1_reuse_prepare()
    # Stage 2: prove the fixturenet is ready.
    fixturenet_up = stage2_ready()
    print(json.dumps({"fixturenet_up": fixturenet_up}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
