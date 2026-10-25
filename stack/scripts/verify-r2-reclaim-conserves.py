#!/usr/bin/env python3
"""stack/scripts/verify-r2-reclaim-conserves.py — R2 scenario (c): a reclaim conserves the
pool's balance.

Stands up or restores the fixturenet from the warm snapshot (stack/scripts/fixturenet-new),
runs the R2-reclaim-conserves job via run-job (never a direct host read of the deployment's own
data directory), reads the job's JSON result back, tears the fixturenet down on exit, and
prints exactly one JSON line to stdout:
    {"balanceOf_before": <int>, "balanceOf_after": <int>, "reclaim": "ok"|"revert",
     "balance_fell": <bool>, "transactionHash": <string>, "revertData": <string>,
     "unlinked_library_revert": <bool>}

The job concludes the source channel (which guarantees the target), concludes the target,
reclaims the guarantee (spend the old pool commitment, mint new ones), and re-reads the pool's
real ERC-20 (USDC) balance before/after. The pool's token balance must NOT fall (Safety.lean's
notedValue_conserved, the reclaim instance).
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
JOB_NAME = "R2-reclaim-conserves"


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
    """Run the R2-reclaim-conserves job via run-job (the sanctioned path -- never a host read of
    the deployment's own data directory). Returns the job's JSON result."""
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
        if isinstance(parsed, dict) and "balanceOf_after" in parsed:
            return parsed
    raise RuntimeError(f"{JOB_NAME} job printed no balanceOf JSON line")


def teardown(dep: Path, env: dict[str, str]) -> None:
    """Guarded teardown on exit: laconic-so deployment stop --delete-volumes, then a guarded
    rm -rf. DEP is set to the deployment dir, so a missing var fails fast (`: "${DEP:?})."""
    run(
        [
            "sh",
            "-c",
            'sudo umount "${DEP}/data" 2>/dev/null || true; '
            'laconic-so deployment --dir "${DEP:?}" stop --delete-volumes; rm -rf "${DEP:?}"',
        ],
        env=env,
    )


def compute_outcome(job_result: dict[str, object]) -> dict[str, object]:
    """The scenario's own verdict, pure: given the job's raw JSON result, decide PASS, FAIL or
    ERROR. Three outcomes, never two: PASS (the reclaim succeeded and the pool's token balance
    did not fall), FAIL (the reclaim succeeded and the balance fell -- or the op reverted with
    the unlinked-library error), ERROR (the reclaim reverted before reaching the pool -- not
    evidence for or against the conservation result either way; the transaction hash and revert
    data are the evidence to investigate next)."""
    balance_of_before = int(str(job_result.get("balanceOf_before", 0)))
    balance_of_after = int(str(job_result.get("balanceOf_after", 0)))
    reclaim = str(job_result.get("reclaim", "ok"))
    balance_fell = job_result.get("balance_fell") is True or balance_of_after < balance_of_before
    transaction_hash = str(job_result.get("transactionHash", ""))
    revert_data = str(job_result.get("revertData", ""))
    unlinked_library_revert = bool(job_result.get("unlinked_library_revert", False))

    if unlinked_library_revert:
        result = "FAIL"
    elif reclaim == "revert":
        result = "ERROR"
    elif balance_fell:
        result = "FAIL"
    else:
        result = "PASS"

    return {
        "balanceOf_before": balance_of_before,
        "balanceOf_after": balance_of_after,
        "reclaim": reclaim,
        "balance_fell": balance_fell,
        "transactionHash": transaction_hash,
        "revertData": revert_data,
        "unlinked_library_revert": unlinked_library_revert,
        "result": result,
    }


def main() -> int:
    name = f"r2-reclaim-conserves-{int(time.time())}-{uuid.uuid4().hex[:6]}"
    dep = Path(os.environ["HOME"]) / "deployments" / name
    env = os.environ.copy()
    env["DEP"] = str(dep)
    env["TMPDIR"] = str(TMPDIR)
    env["ARMADA_IMAGE_TAG"] = run(["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"]).stdout.strip()
    # Stand up or restore the fixturenet from the warm snapshot.
    TMPDIR.mkdir(exist_ok=True)
    run(["bash", str(REPO_ROOT / "stack/scripts/fixturenet-new"), name], env=env)

    try:
        outcome = compute_outcome(run_job(dep, env))
    except RuntimeError as exc:
        outcome = {"unlinked_library_revert": True, "result": "ERROR", "reason": str(exc)}
    finally:
        # Guarded teardown; a teardown failure must not suppress the result line.
        try:
            teardown(dep, env)
        except RuntimeError as exc:
            log(f"teardown failed (result line still printed): {exc}")

    print(json.dumps(outcome))
    return 0


if __name__ == "__main__":
    sys.exit(main())
