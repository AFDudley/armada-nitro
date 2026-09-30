#!/usr/bin/env python3
"""armada-custodian-e2e gate checker (E14c steps 1-2).

Runs the `armada-custodian-e2e` job via `laconic-so deployment --dir <dep> run-job
armada-custodian-e2e` (laconic-so is a Python shiv that only loads under the system
python3.12, not the venv's python3.14), then parses the job's structured JSON output and
re-emits the six required fields:

  authorize_delegate_success, authorize_delegate_tx_hash, close_success, close_tx_hash,
  is_active_delegate, payout_matches_allocations.

Exits 0 when both steps pass; exits non-zero otherwise.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

# The deployment the job runs against (operator-managed fixturenet deployed per E14b).
DEP_DIR = os.path.expanduser("~/deployments/armada-fixturenet-e12")
LA_CONIC_SO = os.path.expanduser("~/bin/laconic-so")
PYTHON_312 = "/usr/bin/python3.12"

# The prebuilt FROST signer binary (workspace root target). The job's container mounts it.
_scripts_dir = os.path.dirname(os.path.abspath(__file__))  # <repo>/scripts
_repo_root = os.path.dirname(_scripts_dir)  # <repo>
FROST_SIGNER = os.path.join(_repo_root, "target/release/frost-signer")


def run_job() -> int:
    """Run the gate job and capture its stdout (the final JSON line)."""
    cmd = [
        PYTHON_312,
        LA_CONIC_SO,
        "deployment",
        "--dir", DEP_DIR,
        "run-job", "armada-custodian-e2e",
    ]
    env = os.environ.copy()
    # The job's container mounts this binary for the FROST flow.
    env["FROST_SIGNER"] = FROST_SIGNER
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=900,
            env=env,
        )
    except subprocess.TimeoutExpired as e:
        print(f"TIMEOUT: job did not finish within 900s", file=sys.stderr)
        return 1

    # Find the job's final JSON line (the structured output the job emits at the end).
    job_stdout = result.stdout or ""
    job_stderr = result.stderr or ""

    # The job emits a final JSON line like:
    # {"authorize_delegate_success": true, "authorize_delegate_tx_hash": "0x...",
    #  "close_success": true, "close_tx_hash": "0x...", "is_active_delegate": true,
    #  "payout_matches_allocations": true}
    # Extract it.
    job_json = None
    for line in job_stdout.splitlines():
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                job_json = json.loads(line)
            except json.JSONDecodeError:
                continue
    if job_json is None:
        # Fall back to the last JSON-looking line.
        for line in reversed(job_stdout.splitlines()):
            line = line.strip()
            if line.startswith("{"):
                try:
                    job_json = json.loads(line)
                    break
                except json.JSONDecodeError:
                    continue
    if job_json is None:
        print(f"run-job failed (exit={result.returncode}).", file=sys.stderr)
        print(job_stdout, file=sys.stderr)
        if job_stderr:
            print(job_stderr, file=sys.stderr)
        return 1 if result.returncode != 0 else 1

    # Re-emit the six required fields (and the exit code for c5).
    out = {
        "authorize_delegate_success": job_json.get("authorize_delegate_success"),
        "authorize_delegate_tx_hash": job_json.get("authorize_delegate_tx_hash", ""),
        "close_success": job_json.get("close_success"),
        "close_tx_hash": job_json.get("close_tx_hash", ""),
        "is_active_delegate": job_json.get("is_active_delegate"),
        "payout_matches_allocations": job_json.get("payout_matches_allocations"),
        "exit_code": result.returncode,
    }
    print(json.dumps(out))
    # Exit 0 only when both steps pass (authorize_delegate_success and close_success are true).
    both_pass = (
        out["authorize_delegate_success"] is True
        and out["close_success"] is True
        and out["payout_matches_allocations"] is True
        and out["is_active_delegate"] is True
        and out["authorize_delegate_tx_hash"] != ""
        and out["close_tx_hash"] != ""
    )
    return 0 if both_pass else 1


def main() -> int:
    return run_job()


if __name__ == "__main__":
    sys.exit(main())
