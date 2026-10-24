#!/usr/bin/env python3
"""stack/scripts/verify-r2-reclaim-conserves.py -- R2 scenario (c) acceptance
(docs/tasks/R2-fixturenet-defect-scenarios.md).

Stands up a fresh fixturenet with stack/scripts/fixturenet-new (run-unique name, TMPDIR set to
the repo .scratch, mirroring stack/scripts/armada-disclosure-acceptance.py), then runs the
armada-r2-reclaim-conserves job (run-job, never a direct host read of the deployment's own data
directory -- gates and runners reach the fixturenet only via run-job and geth RPC). That job
concludes a source channel holding a guarantee allocation and its target (both real-proof
funded and force-moved to finalize), calls `reclaim`, and prints its own JSON result line with
the pool's total token balance for the reclaimed asset before and after the reclaim call.

This script reads that result back from the job's captured output, computes whether the
reported verdict is true to the observed balances, and prints exactly one JSON line to stdout
(all diagnostics go to stderr):
    {"reclaim_called": true, "balance_before": N0, "balance_after": N1,
     "result_reported": true, "verdict_matches_balances": true, "verdict": "FAIL" | "conserved"}

Runs with real proofs end to end and never sets any test-only verification skip flag
(docs/tasks/R2-fixturenet-defect-scenarios.md's constraint). The scenario's own acceptance is
that it runs and reports -- today the job is expected to report FAIL, citing
departures-found.md item 2 (_settleReclaimExit / PoolSpend.settleReclaim mints
priorHeld + guaranteeAmount for the target from one input of priorHeld, with no source debit),
so the pool's balance after the reclaim exceeds the balance before by the guarantee amount; it
passes only once the adjudicator rewrite lands. This scenario is not part of the
commit-boundary gate (.pre-commit-config.yaml does not reference it) -- it is a standalone,
by-hand or by-schedule run.
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
JOB_NAME = "R2-reclaim-conserves"  # stack/compose-jobs/docker-compose-R2-reclaim-conserves.yml


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


def run_reclaim_job(dep: Path, env: dict[str, str]) -> dict[str, object] | None:
    """Run the armada-r2-reclaim-conserves job -- the sanctioned run-job path -- and return its
    JSON result (the last JSON-parseable line of its captured output that carries
    reclaim_called), or None if the job printed no such line (e.g. a revert before the report
    phase ran)."""
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
        if isinstance(parsed, dict) and "reclaim_called" in parsed:
            return parsed
    return None


def _int_field(d: dict[str, object] | None, key: str) -> int:
    """Narrow a json-decoded field (object) to int for mypy --strict."""
    if d is None:
        return 0
    value = d.get(key, 0)
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (int, float, str)):
        return int(value)
    return 0


def teardown(dep: Path, env: dict[str, str]) -> None:
    """Guarded teardown (docs/tasks/R2-fixturenet-defect-scenarios.md: "a guarded
    `laconic-so deployment stop --delete-volumes` then a guarded `rm -rf`")."""
    dep_str = str(dep)
    if not dep_str or dep_str in ("/", str(Path.home())):
        return
    try:
        run([resolve_laconic_so(), "deployment", "--dir", dep_str, "stop", "--delete-volumes"], env=env)
    except Exception as exc:  # noqa: BLE001 -- best-effort teardown, never masks the real result
        log(f"teardown: stop failed (continuing): {exc}")
    if dep.exists() and dep.is_dir() and dep != Path("/"):
        shutil.rmtree(dep, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="print the single JSON result line (always on)")
    parser.parse_args()

    name = f"r2-reclaim-{int(time.time())}-{uuid.uuid4().hex[:6]}"
    dep = Path(os.environ["HOME"]) / "deployments" / name

    TMPDIR.mkdir(exist_ok=True)
    env = os.environ.copy()
    env["TMPDIR"] = str(TMPDIR)
    # Jobs name their image as cerc/armada-nitro-env:${ARMADA_IMAGE_TAG} (arn-895): the image
    # built from this checkout's committed content, tagged with HEAD's sha.
    env["ARMADA_IMAGE_TAG"] = run(["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"]).stdout.strip()

    job_result: dict[str, object] | None = None
    try:
        run(["bash", str(REPO_ROOT / "stack/scripts/fixturenet-new"), name], env=env)
        job_result = run_reclaim_job(dep, env)
    finally:
        teardown(dep, env)

    reclaim_called = bool(job_result and job_result.get("reclaim_called"))
    balance_before = _int_field(job_result, "balance_before")
    balance_after = _int_field(job_result, "balance_after")
    reported_verdict = str(job_result.get("verdict", "")) if job_result else ""

    # c3: the scenario reports a verdict -- conserved only if the balances match, otherwise
    # FAIL. result_reported is true iff the job printed a parseable result line at all.
    result_reported = job_result is not None
    expected_verdict = "conserved" if balance_before == balance_after else "FAIL"
    # c4: when the job reports FAIL, it must cite departures-found.md item 2 (checked
    # directly against the job's own "cites" field, not re-derived here).
    cites_departure_2 = bool(job_result and "departures-found.md item 2" in str(job_result.get("cites", "")))
    verdict_matches_balances = result_reported and (
        reported_verdict == expected_verdict and (expected_verdict == "conserved" or cites_departure_2)
    )

    result = {
        "reclaim_called": reclaim_called,
        "balance_before": balance_before,
        "balance_after": balance_after,
        "guarantee_amount": _int_field(job_result, "guarantee_amount"),
        "result_reported": result_reported,
        "verdict": reported_verdict,
        "verdict_matches_balances": verdict_matches_balances,
    }
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
