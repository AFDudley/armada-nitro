#!/usr/bin/env python3
"""armada-frost-keygen checker (arn-1be).

Runs the armada-frost-keygen job on the E12 fixturenet through the shared job helper
(scripts/armada_job_helper.py, arn-895), which builds the job's image from this
checkout's committed content if it is missing, selects it (ARMADA_IMAGE_TAG via
`laconic-so deploy create --update` -- this also syncs the deployment's compose-jobs, so
the job registers without a manual file copy), and calls run-job. The job's stdout is
parsed for its JSON line; this checker then reads the hub custodian's on-chain group key
via geth RPC (http://127.0.0.1:8545), and re-emits one JSON line:

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
import subprocess
import sys

_scripts_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _scripts_dir)
from armada_job_helper import run_job as _helper_run_job  # noqa: E402

JOB = "armada-frost-keygen"
# E12's hub custodian: the FROST group key the full reconcile deployed (from the
# deployment's manifest, not the data dir).
CUSTODIAN = "0xae2abbde6c9829141675fa0a629a675badbb0d9f"
HOST_RPC = "http://127.0.0.1:8545"


def run_job() -> dict[str, object]:
    """Run the job through the shared helper and capture its final JSON line from the
    job's stdout."""
    job_stdout, returncode = _helper_run_job(JOB, timeout=300)
    if not job_stdout:
        print("TIMEOUT: run-job did not finish within 300s", file=sys.stderr)
        return {}

    job_json: dict[str, object] | None = None
    for line in reversed(job_stdout.splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                job_json = json.loads(line)
                break
            except json.JSONDecodeError:
                continue
    if job_json is None:
        print(f"run-job failed (exit={returncode}):", file=sys.stderr)
        print(job_stdout, file=sys.stderr)
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
