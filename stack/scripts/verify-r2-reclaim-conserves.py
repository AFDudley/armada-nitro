#!/usr/bin/env python3
"""stack/scripts/verify-r2-reclaim-conserves.py -- R2 scenario (c) acceptance
(docs/tasks/R2-fixturenet-defect-scenarios.md).

Stands up a fresh fixturenet with stack/scripts/fixturenet-new (run-unique name, TMPDIR set to
the repo .scratch, mirroring stack/scripts/armada-disclosure-acceptance.py), then runs the
R2-reclaim-conserves job (run-job, never a direct host read of the deployment's own data
directory -- gates and runners reach the fixturenet only via run-job and geth RPC). That job
force-moves a source channel holding a guarantee allocation and its target to finalize them
(no deposit: reclaim's own checks never read either channel's holdings), trials `reclaim`, and
prints its own JSON result line.

This script reads that result back from the job's captured output and prints exactly one JSON
line to stdout (all diagnostics go to stderr):
    {"reclaim_called": true, "balance_before": N0, "balance_after": N1,
     "guarantee_amount": G, "stage": <str|null>, "reason": <str|null>,
     "result_reported": true, "result": "PASS"|"FAIL"|"ERROR"}
and exits 0 regardless of the scenario's own result.

Runs with real proofs end to end and never sets any test-only verification skip flag. Today
the job is expected to report ERROR, stage="reclaim", before departure item 2 is ever reached:
PoolSpend's own commitment-hash computation delegatecalls a fixed, foundry.toml-linked Poseidon
library address that script/Deploy.s.sol never places real bytecode at on the real fixturenet
(confirmed, a real trace) -- operator ruling, 2026-10-25: PoolSpend and the adjudicator deploy
path are code the rewrite replaces, and this scenario is the rewrite's own check that its
deploy places every linked library. This scenario is not part of the commit-boundary gate
(.pre-commit-config.yaml does not reference it) -- it is a standalone, by-hand or by-schedule
run.
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


def run(
    cmd: list[str], env: dict[str, str] | None = None, check: bool = True
) -> subprocess.CompletedProcess[str]:
    run_env = env if env is not None else os.environ.copy()
    log("+ " + " ".join(cmd))
    p = subprocess.run(cmd, env=run_env, capture_output=True, text=True)
    if p.stdout:
        log(p.stdout)
    if p.stderr:
        log(p.stderr)
    if check and p.returncode != 0:
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


def run_reclaim_job(dep: Path, env: dict[str, str]) -> dict[str, object]:
    """Run the R2-reclaim-conserves job -- the sanctioned run-job path -- and return its JSON
    result (the last JSON-parseable line of its captured output that carries a "result" key)."""
    p = run(
        [resolve_laconic_so(), "deployment", "--dir", str(dep), "run-job", JOB_NAME],
        env=env,
        check=False,
    )
    for line in reversed(p.stdout.splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            parsed: object = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict) and "result" in parsed:
            return parsed
    raise RuntimeError(f"{JOB_NAME} job printed no scenario-result JSON line (exit {p.returncode})")


def teardown(dep: Path, env: dict[str, str]) -> None:
    """Guarded teardown on exit (arn-eb0): the shared fixturenet-teardown routine unmounts the
    tmpfs RAM disk, stops the deployment (laconic-so stop --delete-volumes), and removes the
    directory -- matching verify-r2-deposit-conserves.py's own pattern."""
    dep_str = str(dep)
    if not dep_str or dep_str in ("/", str(Path.home())):
        return
    try:
        subprocess.run(
            ["bash", str(REPO_ROOT / "stack/scripts/fixturenet-teardown"), dep_str],
            env=env,
        )
    except Exception as exc:  # noqa: BLE001 -- best-effort teardown, never masks the real result
        log(f"teardown failed (continuing): {exc}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="print the single JSON result line (always on)")
    parser.parse_args()

    name = f"r2-reclaim-{int(time.time())}-{uuid.uuid4().hex[:6]}"
    dep = Path(os.environ["HOME"]) / "deployments" / name

    TMPDIR.mkdir(exist_ok=True)
    env = os.environ.copy()
    env.pop("VERIFICATION_BYPASS", None)
    env["TMPDIR"] = str(TMPDIR)
    # Jobs name their image as cerc/armada-nitro-env:${ARMADA_IMAGE_TAG} (arn-895): the image
    # built from this checkout's committed content, tagged with HEAD's sha.
    env["ARMADA_IMAGE_TAG"] = run(["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"]).stdout.strip()

    try:
        run(["bash", str(REPO_ROOT / "stack/scripts/fixturenet-new"), name], env=env)
        job_result = run_reclaim_job(dep, env)
    finally:
        teardown(dep, env)

    result = {
        "reclaim_called": job_result.get("reclaim_called"),
        "balance_before": job_result.get("balance_before"),
        "balance_after": job_result.get("balance_after"),
        "guarantee_amount": job_result.get("guarantee_amount"),
        "stage": job_result.get("stage"),
        "reason": job_result.get("reason"),
        "result_reported": job_result.get("result") in ("PASS", "FAIL", "ERROR"),
        "result": job_result.get("result"),
    }
    if result["result"] == "FAIL":
        log("FAIL: cited cause: " + str(job_result.get("cites")))
    elif result["result"] == "ERROR":
        log(f"ERROR: stopped at stage={result['stage']!r}, reason={result['reason']!r}")

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
