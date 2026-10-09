#!/usr/bin/env python3
"""armada-frost-keygen checker (arn-1be).

Runs the armada-frost-keygen job on the E12 fixturenet via
`laconic-so deployment --dir <dep> run-job armada-frost-keygen`, then reads the hub
custodian's on-chain group key via geth RPC (http://127.0.0.1:8545), and re-emits one JSON
line:

  {"group_pubkey_x", "group_pubkey_y", "shares_present", "already_present",
   "custodian_group_key_matches"}

The job's own four fields (group_pubkey_x, group_pubkey_y, shares_present, already_present)
are re-emitted as the job reports them; custodian_group_key_matches is true when the job's
group key equals the hub custodian's on-chain key (the 2-of-3 group the full reconcile
deployed). Exits 0 when the job succeeded and the on-chain key matches; non-zero otherwise.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys

# The operator-managed E12 fixturenet (arn-1be's target deployment).
DEP_DIR = os.path.expanduser("~/deployments/armada-fixturenet-e12")
# E12's hub custodian: the FROST group key the full reconcile deployed (from the
# deployment's manifest, not the data dir).
CUSTODIAN = "0xae2abbde6c9829141675fa0a629a675badbb0d9f"
HOST_RPC = "http://127.0.0.1:8545"

# laconic-so is a self-contained shiv (bundled zipapp) loaded under the system python3.12
# (not the venv's python3.14).
_LITERAL_SHIV = "/home/rix/bin/laconic-so"
LA_CONIC_SO = _LITERAL_SHIV if os.path.isfile(_LITERAL_SHIV) else os.path.expanduser("~/bin/laconic-so")
PYTHON_312 = "/usr/bin/python3.12"

_scripts_dir = os.path.dirname(os.path.abspath(__file__))
_repo_root = os.path.dirname(_scripts_dir)
JOB_FILE_SRC = os.path.join(_repo_root, "stack", "compose-jobs", "docker-compose-armada-frost-keygen.yml")
JOB_FILE_DST = os.path.join(DEP_DIR, "compose-jobs", "docker-compose-armada-frost-keygen.yml")


def _ensure_job_registered() -> None:
    """The check script reaches E12 only through `run-job` + geth RPC; copy the job file into
    the deployment's compose-jobs (not its data dir) if it is missing, written atomically so a
    half-file is never observed."""
    if os.path.exists(JOB_FILE_DST):
        return
    os.makedirs(os.path.dirname(JOB_FILE_DST), exist_ok=True)
    tmp = JOB_FILE_DST + ".tmp"
    shutil.copyfile(JOB_FILE_SRC, tmp)
    os.rename(tmp, JOB_FILE_DST)


def run_job() -> dict[str, object]:
    """Run the job and capture its final JSON line from the job's stdout."""
    cmd = [
        PYTHON_312,
        LA_CONIC_SO,
        "deployment",
        "--dir",
        DEP_DIR,
        "run-job",
        "armada-frost-keygen",
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        print("TIMEOUT: run-job did not finish within 300s", file=sys.stderr)
        return {}

    job_json: dict[str, object] | None = None
    for line in reversed((result.stdout or "").splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                job_json = json.loads(line)
                break
            except json.JSONDecodeError:
                continue
    if job_json is None:
        print(f"run-job failed (exit={result.returncode}):", file=sys.stderr)
        if result.stdout:
            print(result.stdout, file=sys.stderr)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        return {}
    return job_json


def _cast_call(sig: str) -> str | None:
    """Read a uint256 from the chain via `cast call` against geth's host-published port."""
    r = subprocess.run(
        ["cast", "call", CUSTODIAN, sig, "--rpc-url", HOST_RPC],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if r.returncode != 0:
        print(f"cast call {sig} failed: {r.stderr.strip()}", file=sys.stderr)
        return None
    # `cast call ...(uint256)` pretty-prints large values as "123 [1.23e5]"; the first token
    # is the raw value.
    return r.stdout.strip().split()[0]


def custodian_key_matches(job_json: dict[str, object] | None) -> bool:
    """custodian_group_key_matches: the job's group key (X, Y, as 0x-hex from
    group-pubkey.json) equals the hub custodian's on-chain key (groupKeyX()/groupKeyY(),
    returned as uint256)."""
    if job_json is None:
        return False
    chain_x = _cast_call("groupKeyX()(uint256)")
    chain_y = _cast_call("groupKeyY()(uint256)")
    if chain_x is None or chain_y is None:
        print("custodian_group_key_matches: on-chain read failed", file=sys.stderr)
        return False

    job_x = job_json.get("group_pubkey_x")
    job_y = job_json.get("group_pubkey_y")
    if not isinstance(job_x, str) or not isinstance(job_y, str) or not job_x or not job_y:
        return False

    # The group public key coordinates are 32-byte hex (0x-prefixed) in group-pubkey.json;
    # the on-chain values are the same coordinates as uint256. Compare the numeric values.
    job_x_bits = int(job_x, 16) if job_x.lower().startswith("0x") else int(job_x)
    job_y_bits = int(job_y, 16) if job_y.lower().startswith("0x") else int(job_y)
    return job_x_bits == int(chain_x) and job_y_bits == int(chain_y)


def main() -> int:
    _ensure_job_registered()
    job_json = run_job()

    # Re-emit the job's four fields as the job reported them (group_pubkey_x, group_pubkey_y,
    # shares_present, already_present), plus the on-chain comparison.
    out = {
        "group_pubkey_x": (job_json or {}).get("group_pubkey_x", ""),
        "group_pubkey_y": (job_json or {}).get("group_pubkey_y", ""),
        "shares_present": (job_json or {}).get("shares_present"),
        "already_present": (job_json or {}).get("already_present"),
        "custodian_group_key_matches": custodian_key_matches(job_json),
    }
    print(json.dumps(out))

    # The checker exits 0 only when the job succeeded (shares_present = 3) AND the on-chain
    # key matches; report the expected values for the acceptance oracle.
    return 0 if ((job_json or {}).get("shares_present") == 3 and out["custodian_group_key_matches"]) else 1


if __name__ == "__main__":
    sys.exit(main())
