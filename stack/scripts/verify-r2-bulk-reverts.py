#!/usr/bin/env python3
"""stack/scripts/verify-r2-bulk-reverts.py — R2 scenario (d): the bulk path reverts
(Safety.lean's bulk_paths_never_succeed).

Stands up or restores the fixturenet from the warm snapshot (stack/scripts/fixturenet-new),
runs the R2-bulk-reverts job via run-job (never a direct host read of the deployment's own
data directory), reads the job's JSON result back, tears the fixturenet down on exit, and
prints exactly one JSON line to stdout:
    {"ran_on_fixturenet": true, "transferAllAssets": "ok"|"revert", "result": "PASS"|"FAIL",
     "departure": "..."}

The job concludes a channel (the e2e scenario's co-signed conclude path) and calls
transferAllAssets on it. The call is expected to REVERT (Safety.lean's bulk_paths_never_succeed).
Today the call SUCCEEDS and mints real spendable notes to every payee with no debit anywhere in
the pool (departure item 5/8, departures-found.md: neither transferAllAssets nor
concludeAndTransferAllAssets is overridden, so both inherited calls succeed; the bulk path mints
payee notes with nullifiers := []). The check reports FAIL and cites departure item 5/8; it
passes unchanged once the adjudicator rewrite lands.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

# ---- paths -----------------------------------------------------------------
SCRIPT = Path(__file__).resolve()
REPO_ROOT = SCRIPT.parents[2]  # <repo>/stack/scripts/... -> <repo>
TMPDIR = REPO_ROOT / ".scratch"
JOB_NAME = "R2-bulk-reverts"  # stack/compose-jobs/docker-compose-R2-bulk-reverts.yml


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def run(cmd: list[str], env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    run_env = env if env is not None else os.environ.copy()
    log("+ " + " ".join(cmd))
    p = subprocess.run(cmd, env=run_env, capture_output=True, text=True)
    if p.stdout:
        log(p.stdout)
    if p.stderr:
        log(p.stderr)
    if p.returncode != 0:
        raise RuntimeError(f"command failed (exit {p.returncode}): {' '.join(cmd)}")
    return p


def resolve_laconic_so() -> str:
    exe = os.environ.get("LACONIC_SO")
    if exe:
        return exe
    exe = shutil.which("laconic-so")
    if not exe:
        raise RuntimeError("laconic-so not found on PATH; set LACONIC_SO or add it to PATH")
    return exe


def run_job(dep: Path, env: dict[str, str]) -> dict[str, object]:
    """Run the R2-bulk-reverts job via run-job (the sanctioned path -- never a host read of the
    deployment's own data directory). Returns the job's JSON result (last JSON-parseable line of
    its captured output)."""
    p = run(
        [resolve_laconic_so(), "deployment", "--dir", str(dep), "run-job", JOB_NAME],
        env=env,
    )
    for line in reversed(p.stdout.splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            parsed: object = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict) and "transferAllAssets" in parsed:
            return parsed
    raise RuntimeError(f"{JOB_NAME} job printed no transferAllAssets JSON line")


def teardown(dep: Path, env: dict[str, str]) -> None:
    """Guarded teardown on exit: umount the fixturenet's RAM disk, laconic-so deployment stop
    --delete-volumes, then a guarded rm -rf. DEP is set to the deployment dir (a missing var fails
    fast via ${DEP:?})."""
    run(
        [
            "sh",
            "-c",
            'umount "${DEP}/data" 2>/dev/null; '
            'laconic-so deployment --dir "${DEP:?}" stop --delete-volumes; rm -rf "${DEP:?}"',
        ],
        env=env,
    )


def main() -> int:
    name = f"r2-bulk-reverts-{int(time.time())}-{uuid.uuid4().hex[:6]}"
    dep = Path(os.environ["HOME"]) / "deployments" / name
    env = os.environ.copy()
    env["DEP"] = str(dep)

    # Stand up or restore the fixturenet from the warm snapshot (cold path builds + snapshots the
    # base layer; warm path restores it).
    TMPDIR.mkdir(exist_ok=True)
    env["TMPDIR"] = str(TMPDIR)
    env["ARMADA_IMAGE_TAG"] = run(["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"]).stdout.strip()
    run(["bash", str(REPO_ROOT / "stack/scripts/fixturenet-new"), name], env=env)

    outcome = None
    try:
        job_result = run_job(dep, env)
        transfer_all_assets = str(job_result.get("transferAllAssets", "ok"))
        channel_id = str(job_result.get("channelId", ""))
        concluded = job_result.get("concluded") is True

        # transferAllAssets on a concluded channel must REVERT (Safety.lean's bulk_paths_never_succeed).
        result = "PASS"
        if transfer_all_assets != "revert" or not concluded:
            result = "FAIL"

        departure = "departure item 5/8 (departures-found.md): neither transferAllAssets nor concludeAndTransferAllAssets is overridden, so both inherited calls succeed and mint real spendable notes to every payee with no debit anywhere in the pool (PoolSpend.mintPayoutCommitmentsNoChannel, nullifiers := [])."

        outcome = {
            "ran_on_fixturenet": True,
            "concluded": concluded,
            "channelId": channel_id,
            "transferAllAssets": transfer_all_assets,
            "result": result,
            "departure": departure,
        }
    except RuntimeError as exc:
        outcome = {"ran_on_fixturenet": True, "result": "FAIL", "reason": str(exc)}
    finally:
        # Guarded teardown; a teardown failure must not suppress the scenario's result line.
        try:
            teardown(dep, env)
        except RuntimeError as exc:
            log(f"teardown failed (result line still printed): {exc}")

    print(json.dumps(outcome))
    return 0


if __name__ == "__main__":
    sys.exit(main())
