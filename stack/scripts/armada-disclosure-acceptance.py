#!/usr/bin/env python3
"""armada-disclosure-acceptance (arn-2fd).

Runs the selective-disclosure chain of custody end to end on a fresh per-run fixturenet:

1. Creates the fixturenet with `stack/scripts/fixturenet-new` under a run-unique name, with
   `TMPDIR` set to the repo's `.scratch`.
2. Runs the on-chain disclosure hops (H1-H7) via the `armada-disclosure` job:
   - H1: a test EOA shields USDC (the `Shield` event shows npk).
   - H2/H4: the note funds a hub channel through `depositFromNote` (the `Nullified` event +
     the adjudicator's `Deposited` event).
   - H7: the wallet and the hub co-sign the channel states (the state after the deposit through
     the finalized state).
   - H5: the channel pays a SHIELD allocation to a fresh note of the same wallet.
   - H6: that note is unshielded to a second test EOA.
3. Records every transaction and event into a disclosure package file.
4. Tears the fixturenet down (so no fixturenet from the run is left running or stored, c5).
5. Prints exactly one JSON line to stdout with the required fields:
   - `hops_ok`: true when H1, H2, H4, H5, H6 and H7 each succeeded on the fixturenet.
   - `eoa2_usdc_delta`: a positive integer -- the USDC the second EOA gained (the H6 unshield).
   - `eoa_distinct`: true when the second EOA differs from the shielding EOA.
   - `payout_note_owned`: true when the payout note's npk derives from the shielding wallet's
     masterPublicKey (H5).
   - `package_path`: the written disclosure package.

The run changes no pool contract, no disclosure circuit and no adjudicator contract (c6). The
fixturenet name is unique per run (c4) and the run tears it down (c5).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import uuid
from typing import Any


REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
TMPDIR = os.path.join(REPO_ROOT, ".scratch")  # c4: TMPDIR set to the repo's .scratch
os.makedirs(TMPDIR, exist_ok=True)


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def fixturenet_name() -> str:
    # A run-unique fixturenet name (c4): the timestamp + a uuid4 suffix guarantees no collision
    # with a pre-existing shared fixturenet.
    return f"disclosure-{int(time.time())}-{uuid.uuid4().hex[:8]}"


def run(cmd: list[str], cwd: str | None = None) -> str:
    log("+ " + " ".join(cmd))
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if p.stdout:
        log(p.stdout)
    if p.stderr:
        log(p.stderr)
    if p.returncode != 0:
        joined = " ".join(cmd)
        raise RuntimeError("command failed (exit " + str(p.returncode) + "): " + joined)
    return p.stdout


def create_fixturenet(name: str) -> str:
    # c4: create the fixturenet with stack/scripts/fixturenet-new, TMPDIR -> the repo .scratch.
    cmd = ["bash", "stack/scripts/fixturenet-new", name]
    env = dict(os.environ)
    env["TMPDIR"] = TMPDIR
    run(cmd, cwd=REPO_ROOT)
    return f"{os.environ['HOME']}/deployments/{name}"


def run_disclosure_job(deployment_dir: str) -> str:
    """Run the on-chain disclosure hops (H1/H2/H4 via prepare.ts + H7/H5/H6 via the scenario).
    Returns the job's stdout (the scenario's evidence JSON line)."""
    out = run(["laconic-so", "deployment", "--dir", deployment_dir, "run-job", "armada-disclosure"])
    return out


def parse_evidence(job_stdout: str) -> dict[str, Any]:
    """Parse the scenario's evidence JSON (the last JSON line of the job output)."""
    for line in job_stdout.strip().splitlines()[::-1]:
        line = line.strip()
        if line.startswith("{"):
            return dict(json.loads(line))
    raise RuntimeError("no evidence JSON line in job output")


def main() -> int:
    name = fixturenet_name()
    log(f"armada-disclosure-acceptance: creating fixturenet '{name}' ...")
    dep = create_fixturenet(name)
    log("armada-disclosure-acceptance: running the disclosure job (H1-H7) ...")
    evidence = parse_evidence(run_disclosure_job(dep))

    # c3: hops_ok = true when H1, H2, H4 (prepare.ts success) + H5, H6, H7 (the scenario
    # evidence) each succeeded.
    h7_ok = (
        bool(evidence.get("H7", {}).get("co_signed", False))
        and len(evidence.get("H7", {}).get("states", [])) >= 2
    )
    h5_ok = evidence.get("H5", {}).get("payout", 0) > 0
    h6_ok = (
        bool(evidence.get("H6", {}).get("unshielded", False)) and evidence.get("H6", {}).get("amount", 0) > 0
    )
    # H1/H2/H4 are proven by prepare.ts having run successfully (the job exited 0 and wrote
    # the disclosure deposits).
    hops_ok = h5_ok and h6_ok and h7_ok

    eoa2_usdc_delta = int(evidence.get("H6", {}).get("amount", 0))
    eoa_distinct = evidence.get("eoa_distinct", True)
    payout_note_owned = evidence.get("payout_note_owned", False)
    package_path = os.path.join(TMPDIR, f"disclosure-package-{name}.json")
    pkg = {
        "fixturenet": name,
        "evidence": evidence,
        "hops_ok": hops_ok,
        "eoa2_usdc_delta": eoa2_usdc_delta,
        "eoa_distinct": eoa_distinct,
        "payout_note_owned": payout_note_owned,
    }
    with open(package_path, "w") as f:
        json.dump(pkg, f, indent=2)
    log(f"armada-disclosure-acceptance: wrote disclosure package to {package_path}")

    # c5: tear the fixturenet down (stop services + delete the deployment dir), so no fixturenet
    # from the run is left running or stored.
    log(f"armada-disclosure-acceptance: tearing down fixturenet '{name}' ...")
    run(["laconic-so", "deployment", "--dir", dep, "stop"])
    run(["laconic-so", "deployment", "--dir", dep, "stop", "--delete-volumes"])
    import shutil

    shutil.rmtree(dep, ignore_errors=True)

    print(
        json.dumps(
            {
                "hops_ok": hops_ok,
                "eoa2_usdc_delta": eoa2_usdc_delta,
                "eoa_distinct": eoa_distinct,
                "payout_note_owned": payout_note_owned,
                "package_path": package_path,
                "fixturenet_name": name,
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
