#!/usr/bin/env python3
"""stack/scripts/verify-owned-spend-ops.py — arn-831 c4: the owned-spend operations
(depositFromNote and transfer) both finish successfully on a real fixturenet, with no
'delegatecall to non-contract address' error.

Stands up or restores the fixturenet from the warm snapshot (stack/scripts/fixturenet-new),
runs each selected op's job via run-job (never a direct host read of the deployment's own data
directory), reads each job's JSON result back, tears the fixturenet down on exit, and prints
exactly one JSON line to stdout:
    {"ops": {"depositFromNote": "ok"|"revert", "transfer": "ok"|"revert"},
     "unlinked_library_revert": <bool>}

The `--ops` argument selects which ops to run (comma-separated: depositFromNote, transfer).
Each op's job reports its own verdict; `unlinked_library_revert` is true only when one of the
selected ops reverted with the 'delegatecall to non-contract address' error (a linked Poseidon
library not found).
"""

from __future__ import annotations

import argparse
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

# op -> job name mapping (stack/compose-jobs/).
_OP_JOBS = {
    "depositFromNote": "R2-deposit-conserves",
    "transfer": "R2-transfer-conserves",
}
# op -> the job's JSON field that carries the op's own verdict ("ok"/"revert").
_OP_RESULT_FIELD = {
    "depositFromNote": "depositFromNote",
    "transfer": "transfer",
}


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


def run_job(job_name: str, dep: Path, env: dict[str, str]) -> dict[str, object]:
    """Run a job via run-job (the sanctioned path -- never a host read of the deployment's own
    data directory). Returns the job's JSON result (last JSON-parseable dict line of its output)."""
    p = run(
        [resolve_laconic_so(), "deployment", "--dir", str(dep), "run-job", job_name],
        env=env,
    )
    # Find the last JSON-parseable dict line (the job's result).
    result: object = None
    for line in reversed(p.stdout.splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            result = parsed
            break
    if result is None:
        raise RuntimeError(f"{job_name} job printed no JSON line")
    return parsed


def is_unlinked_library_revert(result: dict[str, object]) -> bool:
    """A revert is an 'unlinked library' revert when the op reverted AND the revert data
    mentions the 'delegatecall to non-contract address' error (a linked library not found)."""
    revert_data = str(result.get("revertData", ""))
    revert_data_lower = revert_data.lower()
    # Check the op's own verdict field.
    op_verdict = None
    if "depositFromNote" in result:
        if result["depositFromNote"] == "revert":
            if "delegatecall" in revert_data_lower or "non-contract" in revert_data_lower:
                return True
    if "transfer" in result:
        if result["transfer"] == "revert":
            if "delegatecall" in revert_data_lower or "non-contract" in revert_data_lower:
                return True
    # Fallback: check the job's own unlinked_library_revert field if present.
    if "unlinked_library_revert" in result:
        return bool(result["unlinked_library_revert"])
    return False


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


def main() -> int:
    parser = argparse.ArgumentParser(description="Run owned-spend ops on the fixturenet and report unlinked-library reverts")
    parser.add_argument("--ops", required=True, help="comma-separated ops to run (depositFromNote, transfer)")
    args = parser.parse_args()

    # Parse --ops and map each op to its scenario job.
    ops = [op.strip() for op in args.ops.split(",") if op.strip()]
    for op in ops:
        if op not in _OP_JOBS:
            print(f"verify-owned-spend-ops: unknown op '{op}; known ops: {list(_OP_JOBS.keys())}", file=sys.stderr)
        # Each op must map to a job; the c4 spec says both ops finish successfully.
        if op not in _OP_JOBS:
            return 1

    name = f"owned-spend-ops-{int(time.time())}-{uuid.uuid4().hex[:6]}"
    dep = Path(os.environ["HOME"]) / "deployments" / name
    env = os.environ.copy()
    env["DEP"] = str(dep)
    env["TMPDIR"] = str(TMPDIR)
    env["ARMADA_IMAGE_TAG"] = run(["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"]).stdout.strip()

    # Stand up or restore the fixturenet from the warm snapshot.
    TMPDIR.mkdir(exist_ok=True)
    run(["bash", str(REPO_ROOT / "stack/scripts/fixturenet-new"), name], env=env)

    try:
        # Run each selected op's job, reading back its JSON result.
        op_results = {}
        unlinked = False
        for op in ops:
            result = run_job(_OP_JOBS[op], dep, env)
            # Record the op's own verdict (ok/revert) and aggregate the unlinked-library flag.
            op_results[op] = result.get(_OP_RESULT_FIELD[op], "error")
            unlinked = unlinked or is_unlinked_library_revert(result)
        outcome = {
            "ops": op_results,
            "unlinked_library_revert": unlinked,
        }
    except RuntimeError as exc:
        outcome = {"unlinked_library_revert": True, "reason": str(exc)}
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
