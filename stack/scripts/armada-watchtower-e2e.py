#!/usr/bin/env python3
"""armada-watchtower-e2e gate (E15).

Proves, on the fixturenet, that a participant holding a newer co-signed channel state defeats a
stale force-close if its watcher answers within the dispute window (scenario A), and loses that
advantage if the watcher is off (scenario B).

Both scenarios share one channel setup, built fresh each run:
  - env/gates/watchtower/prepare.ts shields USDC from a test account and builds a Groth16-proved
    `depositFromNote` unshield to the adjudicator, for two channels (one per scenario), each
    funded for the full amount both STATE_N and STATE_N+1 need (see
    script/WatchtowerScenario.s.sol's header).
  - script/WatchtowerScenario.s.sol does the on-chain parts: fund + the hub's stale challenge
    with state N (`openAndChallenge`); scenario A's watcher response with the newer, final,
    fully-signed state N+1 (`respond` -- `concludeAndTransferAllAssets`, which finalizes and pays
    out in one transaction, regardless of the outstanding challenge); scenario B's settlement of
    the stale state N once the challenge window elapses (`settleStale`); and reading each
    scenario's payout from the Shield logs (`payoutSince`).

Usage:
    python3 stack/scripts/armada-watchtower-e2e.py \
        --state-n-allocation-lamports 1000000 --state-n-plus1-allocation-lamports 2000000

Environment overrides (all optional):
    ARMADA_STATE_DIR   deployment state dir (default ~/deployments/armada-fixturenet-e12/data/armada_env)
    ARMADA_RPC_URL     execution RPC (default http://127.0.0.1:8545, or the target's network.hostRpcUrl)
    ARMADA_POC_DIR     armada-poc checkout for the hardhat deposit script (default /src/armada-poc)
    CHALLENGE_DURATION_SECONDS  the ForceMove challenge window (default 20)

Prints exactly one JSON object to stdout (all narration goes to stderr):
    {
      "scenario_a": {"watcher_enabled": true, "challenge_tx": "0x..", "response_tx": "0x..",
                      "response_latency_seconds": <float>, "payout_lamports": <int>,
                      "check_line": "..."},
      "scenario_b": {"watcher_enabled": false, "challenge_tx": "0x..", "response_tx": "",
                      "payout_lamports": <int>, "check_line": "..."}
    }
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time
from typing import Any

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
WORK_DIR = REPO_ROOT / "deployments" / "watchtower-e2e"
DEPOSITS_PATH = WORK_DIR / "deposits.json"
MANIFEST_PATH = WORK_DIR / "manifest.json"
KEYS_DIR = WORK_DIR

DEFAULT_STATE_DIR = pathlib.Path.home() / "deployments" / "armada-fixturenet-e12" / "data" / "armada_env"
DEFAULT_RPC_URL = "http://127.0.0.1:8545"
DEFAULT_POC_DIR = pathlib.Path("/src/armada-poc")
HUB_RESERVE_LAMPORTS = 500_000
SHIELD_SCRIPT_NAME = "watchtower-prepare.ts"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def state_dir() -> pathlib.Path:
    env = os.environ.get("ARMADA_STATE_DIR")
    return pathlib.Path(env) if env else DEFAULT_STATE_DIR


def rpc_url() -> str:
    return os.environ.get("ARMADA_RPC_URL", DEFAULT_RPC_URL)


def poc_dir() -> pathlib.Path:
    env = os.environ.get("ARMADA_POC_DIR")
    return pathlib.Path(env) if env else DEFAULT_POC_DIR


def _run(
    cmd: list[str],
    cwd: pathlib.Path,
    env: dict[str, str],
    allow_sudo_retry: bool = False,
) -> "subprocess.CompletedProcess[str]":
    log(f"+ {' '.join(cmd)} (cwd={cwd})")
    proc = subprocess.run(cmd, cwd=str(cwd), env=env, capture_output=True, text=True)
    log(proc.stdout)
    if proc.stderr:
        log(proc.stderr)
    if proc.returncode != 0 and allow_sudo_retry and "sudo" not in cmd[0]:
        combined = (proc.stdout + proc.stderr).lower()
        if "permission denied" in combined or "eacces" in combined:
            log("permission denied; retrying under sudo -E")
            sudo_cmd = ["sudo", "-E", "env", f"PATH={env.get('PATH', os.environ['PATH'])}"] + cmd
            log(f"+ {' '.join(sudo_cmd)} (cwd={cwd})")
            proc = subprocess.run(sudo_cmd, cwd=str(cwd), env=env, capture_output=True, text=True)
            log(proc.stdout)
            if proc.stderr:
                log(proc.stderr)
    if proc.returncode != 0:
        raise RuntimeError(f"command failed (exit {proc.returncode}): {' '.join(cmd)}")
    return proc


def _write_private_key(path: pathlib.Path, hex_key: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(hex_key.strip())


def stage_env(manifest_src: pathlib.Path) -> dict[str, Any]:
    """Copy the manifest and the keys this gate needs into a repo-local, forge-fs_permissions
    -compatible staging dir (fs_permissions in foundry.toml only allows "./deployments" and
    "/env", not an arbitrary deployment path on the host)."""
    if WORK_DIR.exists():
        shutil.rmtree(WORK_DIR)
    WORK_DIR.mkdir(parents=True)

    manifest: dict[str, Any] = json.loads(manifest_src.read_text())
    MANIFEST_PATH.write_text(json.dumps(manifest))

    deployer_key_file = manifest_src.parent / "deployer.key"
    deployer_key = None
    if deployer_key_file.exists():
        try:
            deployer_key = deployer_key_file.read_text().strip()
        except PermissionError:
            deployer_key = None
    if deployer_key is None:
        deployer_key = os.environ.get("DEPLOYER_KEY")
    if deployer_key is None:
        config_env = manifest_src.parent.parent.parent / "config.env"
        if config_env.exists():
            for line in config_env.read_text().splitlines():
                if line.startswith("DEPLOYER_KEY="):
                    deployer_key = line.split("=", 1)[1].strip()
                    break
    if deployer_key is None:
        raise RuntimeError(
            f"no readable deployer key at {deployer_key_file}, no DEPLOYER_KEY env var, and no "
            "DEPLOYER_KEY in the deployment's config.env"
        )
    _write_private_key(WORK_DIR / "deployer.key", deployer_key)

    for account in manifest["testAccounts"][:2]:
        key_file = manifest_src.parent / account["privateKeyFile"]
        dest = KEYS_DIR / account["privateKeyFile"]
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(key_file, dest)

    return manifest


def build_deposits(challenge_duration: int, deposit_amount_units: int) -> None:
    src = REPO_ROOT / "env" / "gates" / "watchtower" / "prepare.ts"
    dest_dir = poc_dir() / "scripts" / "gates"
    dest = dest_dir / SHIELD_SCRIPT_NAME
    try:
        dest_dir.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dest)
    except PermissionError:
        subprocess.run(["sudo", "mkdir", "-p", str(dest_dir)], check=True)
        subprocess.run(["sudo", "chown", f"{os.getuid()}:{os.getgid()}", str(dest_dir)], check=True)
        shutil.copyfile(src, dest)

    env = dict(os.environ)
    env.update(
        {
            "MANIFEST_PATH": str(MANIFEST_PATH),
            "DEPOSITS_OUTPUT": str(DEPOSITS_PATH),
            "CHALLENGE_DURATION": str(challenge_duration),
            "DEPOSIT_AMOUNT_UNITS": str(deposit_amount_units),
            "HUB_RPC": rpc_url(),
            "DEPLOY_ENV": "local",
            "CCTP_MODE": "real",
        }
    )
    _run(
        ["npx", "hardhat", "run", f"scripts/gates/{SHIELD_SCRIPT_NAME}", "--network", "hub"],
        cwd=poc_dir(),
        env=env,
        allow_sudo_retry=True,
    )


def forge_env(challenge_duration: int, state_n: int, state_n1: int) -> dict[str, str]:
    env = dict(os.environ)
    env.update(
        {
            "MANIFEST_PATH": str(MANIFEST_PATH),
            "KEYS_DIR": str(KEYS_DIR),
            "DEPOSITS_PATH": str(DEPOSITS_PATH),
            "CHALLENGE_DURATION": str(challenge_duration),
            "STATE_N_USER": str(state_n),
            "STATE_N1_USER": str(state_n1),
            "HUB_RESERVE": str(HUB_RESERVE_LAMPORTS),
        }
    )
    return env


def forge_script(sig: str, args: list[str], env: dict[str, str], broadcast: bool) -> str:
    cmd = ["forge", "script", "script/WatchtowerScenario.s.sol", "--sig", sig, *args, "--rpc-url", rpc_url()]
    if broadcast:
        cmd.append("--broadcast")
    proc = _run(cmd, cwd=REPO_ROOT, env=env)
    return str(proc.stdout)


def broadcast_tx_hash(sig_name: str, function_prefix: str) -> str:
    path = REPO_ROOT / "broadcast" / "WatchtowerScenario.s.sol" / "31337" / f"{sig_name}-latest.json"
    data = json.loads(path.read_text())
    for tx in data["transactions"]:
        if (tx.get("function") or "").startswith(function_prefix):
            return str(tx["hash"])
    raise RuntimeError(f"no {function_prefix} transaction found in {path}")


def _as_int(value: Any) -> int:
    return int(value, 16) if isinstance(value, str) and value.startswith("0x") else int(value)


def tx_block_timestamp(tx_hash: str) -> int:
    receipt = subprocess.run(
        ["cast", "receipt", tx_hash, "--rpc-url", rpc_url(), "--json"],
        capture_output=True,
        text=True,
        check=True,
    )
    block_number = _as_int(json.loads(receipt.stdout)["blockNumber"])
    block = subprocess.run(
        ["cast", "block", str(block_number), "--rpc-url", rpc_url(), "--json"],
        capture_output=True,
        text=True,
        check=True,
    )
    block_data = json.loads(block.stdout)
    block_data = block_data.get("data", block_data)  # cast's block --json wraps in {data: {...}}
    return _as_int(block_data["timestamp"])


def parse_payout(stdout: str) -> int:
    m = re.search(r"PAYOUT_LAMPORTS\s+(\d+)", stdout)
    if not m:
        raise RuntimeError(f"no PAYOUT_LAMPORTS line in forge output:\n{stdout}")
    return int(m.group(1))


def run_scenario_a(challenge_duration: int, state_n: int, state_n1: int) -> dict[str, Any]:
    log("\n=== Scenario A: watcher ON ===")
    env = forge_env(challenge_duration, state_n, state_n1)
    forge_script("openAndChallenge(uint256)", ["0"], env, broadcast=True)
    challenge_tx = broadcast_tx_hash("openAndChallenge", "challenge(")

    forge_script("respond(uint256)", ["0"], env, broadcast=True)
    response_tx = broadcast_tx_hash("respond", "concludeAndTransferAllAssets(")

    challenge_ts = tx_block_timestamp(challenge_tx)
    response_ts = tx_block_timestamp(response_tx)
    latency = max(0, response_ts - challenge_ts)

    payout_stdout = forge_script("payoutSince(uint256)", ["0"], env, broadcast=False)
    payout = parse_payout(payout_stdout)

    expected_net = state_n1 - (state_n1 * 50) // 10_000
    passed = payout == expected_net and payout > (state_n + state_n1) // 2 and response_tx != ""
    check_line = (
        f"scenario A: PASS -- watcher answered in time, payout {payout} lamports "
        f"(state N+1's {state_n1} net of the shield fee)"
        if passed
        else f"scenario A: FAIL -- payout {payout} lamports, expected {expected_net}"
    )
    log(check_line)

    return {
        "watcher_enabled": True,
        "challenge_tx": challenge_tx,
        "response_tx": response_tx,
        "response_latency_seconds": float(latency),
        "payout_lamports": payout,
        "check_line": check_line,
    }


def run_scenario_b(challenge_duration: int, state_n: int, state_n1: int) -> dict[str, Any]:
    log("\n=== Scenario B: watcher OFF ===")
    env = forge_env(challenge_duration, state_n, state_n1)
    forge_script("openAndChallenge(uint256)", ["1"], env, broadcast=True)
    challenge_tx = broadcast_tx_hash("openAndChallenge", "challenge(")

    wait_s = challenge_duration + 5
    log(f"watcher is off; waiting out the {challenge_duration}s challenge window ({wait_s}s)...")
    time.sleep(wait_s)

    forge_script("settleStale(uint256)", ["1"], env, broadcast=True)

    payout_stdout = forge_script("payoutSince(uint256)", ["1"], env, broadcast=False)
    payout = parse_payout(payout_stdout)

    expected_net = state_n - (state_n * 50) // 10_000
    passed = payout == expected_net and payout < (state_n + state_n1) // 2
    check_line = (
        f"scenario B: PASS -- no watcher response, stale challenge stood, payout {payout} "
        f"lamports (state N's {state_n} net of the shield fee)"
        if passed
        else f"scenario B: FAIL -- payout {payout} lamports, expected {expected_net}"
    )
    log(check_line)

    return {
        "watcher_enabled": False,
        "challenge_tx": challenge_tx,
        "response_tx": "",
        "payout_lamports": payout,
        "check_line": check_line,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-n-allocation-lamports", type=int, required=True)
    parser.add_argument("--state-n-plus1-allocation-lamports", type=int, required=True)
    args = parser.parse_args()

    state_n = args.state_n_allocation_lamports
    state_n1 = args.state_n_plus1_allocation_lamports
    if state_n1 <= state_n:
        print("state N+1's allocation must be greater than state N's", file=sys.stderr)
        return 2

    challenge_duration = int(os.environ.get("CHALLENGE_DURATION_SECONDS", "20"))
    deposit_amount_units = state_n1 + HUB_RESERVE_LAMPORTS

    manifest_src = state_dir() / "manifest.json"
    if not manifest_src.exists():
        print(f"no manifest at {manifest_src}", file=sys.stderr)
        return 2

    stage_env(manifest_src)
    build_deposits(challenge_duration, deposit_amount_units)

    scenario_a = run_scenario_a(challenge_duration, state_n, state_n1)
    scenario_b = run_scenario_b(challenge_duration, state_n, state_n1)

    result = {"scenario_a": scenario_a, "scenario_b": scenario_b}
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
