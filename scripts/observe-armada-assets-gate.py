#!/usr/bin/env python3
"""armada-assets-e2e gate observer (arn-273, E11).

Runs scripts/armada-assets-e2e.py (`--mode full` without --skip-borrow,
`--mode skip-borrow` with it), then makes the pass/fail call the gate
script itself does not: that pool.getReserveNormalizedIncome(usdc) and
vault.convertToAssets(vault.balanceOf(hub)) both increased over the wait.
armada-assets-e2e.py only reports the raw before/after numbers; this
script computes the deltas, asserts them, and sets its own exit code from
that assertion -- 0 when both increased (the --mode full case), nonzero
otherwise (the --mode skip-borrow case, where the borrow step is skipped
so neither is expected to increase).

It also runs scripts/armada-assets-e2e-teardown-check.py after the gate
exits, to report whether a deployment is still running and whether the
deployment directory still exists.

Prints one JSON line:
{"gate_exit_code", "scenarios_run", "started_from_warm_snapshot",
 "wait_seconds", "normalized_income_delta", "vault_assets_delta",
 "usdc_gain_minus_principal", "evidence_line_count",
 "running_deployments_after_exit", "deployment_dir_exists_after_exit"}

Run: python3 scripts/observe-armada-assets-gate.py --mode full|skip-borrow
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

SCRIPT = Path(__file__).resolve()
SCRIPTS_DIR = SCRIPT.parent
GATE = SCRIPTS_DIR / "armada-assets-e2e.py"
TEARDOWN_CHECK = SCRIPTS_DIR / "armada-assets-e2e-teardown-check.py"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def run_gate(skip_borrow: bool) -> tuple[int, dict[str, Any], int]:
    """Run the gate, return (exit_code, final_json, evidence_line_count)."""
    cmd = ["python3", str(GATE)]
    if skip_borrow:
        cmd.append("--skip-borrow")
    log("+ " + " ".join(cmd))
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.stderr:
        log(p.stderr)
    lines = [line for line in p.stdout.splitlines() if line.strip()]
    json_lines = [line for line in lines if line.strip().startswith("{")]
    evidence_lines = [line for line in lines if not line.strip().startswith("{")]
    if not json_lines:
        raise RuntimeError(f"armada-assets-e2e.py printed no final JSON line (exit {p.returncode})")
    final: dict[str, Any] = json.loads(json_lines[-1])
    return p.returncode, final, len(evidence_lines)


def run_teardown_check() -> dict[str, Any]:
    p = subprocess.run(["python3", str(TEARDOWN_CHECK)], capture_output=True, text=True)
    if p.stderr:
        log(p.stderr)
    out: dict[str, Any] = json.loads(p.stdout.strip().splitlines()[-1])
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="armada-assets-e2e gate observer (arn-273)")
    ap.add_argument("--mode", choices=["full", "skip-borrow"], default="full")
    args = ap.parse_args()

    gate_returncode, gate_json, evidence_line_count = run_gate(skip_borrow=args.mode == "skip-borrow")
    if gate_returncode != 0:
        raise RuntimeError(f"armada-assets-e2e.py exited {gate_returncode} before producing a result")

    teardown_state = run_teardown_check()

    normalized_income_delta = gate_json["income_after"] - gate_json["income_before"]
    vault_assets_delta = gate_json["vault_assets_after"] - gate_json["vault_assets_before"]
    usdc_gain_minus_principal = (gate_json["bal_after"] - gate_json["bal_before"]) - gate_json["principal"]

    # The gate script never asserts; this is the one place the yield check's
    # own pass/fail is decided. Mode-agnostic on purpose (arn-273's c4: a
    # --skip-borrow run is expected to fail this same assertion, not take a
    # different code path for it).
    yield_increased = normalized_income_delta > 0 and vault_assets_delta > 0
    gate_exit_code = 0 if yield_increased else 1

    result = {
        "gate_exit_code": gate_exit_code,
        "scenarios_run": 2,
        "started_from_warm_snapshot": bool(gate_json["fixturenet_up"]),
        "wait_seconds": gate_json["wait_seconds"],
        "normalized_income_delta": normalized_income_delta,
        "vault_assets_delta": vault_assets_delta,
        "usdc_gain_minus_principal": usdc_gain_minus_principal,
        "evidence_line_count": evidence_line_count,
        "running_deployments_after_exit": 1 if teardown_state["deployment_running"] else 0,
        "deployment_dir_exists_after_exit": bool(teardown_state["deployment_dir_exists"]),
    }
    print(json.dumps(result))
    sys.exit(gate_exit_code)


if __name__ == "__main__":
    main()
