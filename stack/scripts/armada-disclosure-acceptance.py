#!/usr/bin/env python3
"""stack/scripts/armada-disclosure-acceptance.py — the selective-disclosure harness acceptance.

Stands up a fresh fixturenet with stack/scripts/fixturenet-new (run-unique name, TMPDIR set
to the repo .scratch) which builds and snapshots the base layer so a later run is warm. The
shared wallet + proof code lives in env/gates/nitro-e2e/prepare.ts (createWallet + the Groth16
prover via lib/sdk/wallet + lib/sdk/prover), reused by the gate stage the harness builds on.

Brings the fixturenet to ready by running the armada-disclosure compose job (run-job, never a
direct host read of the deployment's own data directory -- gates and runners reach the
fixturenet only via run-job and geth RPC): that job proves the pool, the HubCustodian and the
adjudicator respond on the fixturenet RPC and prints its own JSON result line, which this
script reads back from the job's captured output.

Prints exactly one JSON line to stdout (all diagnostics go to stderr):
    {"harness_files_present": true, "fixturenet_up": true, "snapshot_present": true}
and exits 0.
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
TMPDIR = REPO_ROOT / ".scratch"  # TMPDIR is set to the repo .scratch
DISCLOSURE_JOB = "armada-disclosure"  # stack/compose-jobs/docker-compose-armada-disclosure.yml


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


def run_disclosure_job(dep: Path, env: dict[str, str]) -> dict[str, object]:
    """Run the armada-disclosure job -- the sanctioned run-job path, never a host read of the
    deployment's own state -- which proves, from inside the deployment's own docker network,
    that the pool, the HubCustodian and the adjudicator respond on the fixturenet RPC. Returns
    its JSON result (the last JSON-parseable line of its captured output)."""
    p = run(
        [resolve_laconic_so(), "deployment", "--dir", str(dep), "run-job", DISCLOSURE_JOB],
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
        if isinstance(parsed, dict) and "fixturenet_up" in parsed:
            return parsed
    raise RuntimeError(f"{DISCLOSURE_JOB} job printed no fixturenet_up JSON line")


def main() -> int:
    name = f"disclosure-{int(time.time())}-{uuid.uuid4().hex[:6]}"
    dep = Path(os.environ["HOME"]) / "deployments" / name

    # c3: stand up a fresh fixturenet with stack/scripts/fixturenet-new (run-unique name,
    # TMPDIR = repo .scratch). The cold path builds + snapshots the base layer; the warm
    # path restores it.
    TMPDIR.mkdir(exist_ok=True)
    env = os.environ.copy()
    env["TMPDIR"] = str(TMPDIR)
    # Jobs name their image as cerc/armada-nitro-env:${ARMADA_IMAGE_TAG} (arn-895): the image
    # built from this checkout's committed content, tagged with HEAD's sha. fixturenet-new
    # exports this in its own process; run-job below is a separate process, so export it here
    # too (same `git rev-parse HEAD` fixturenet-new uses).
    env["ARMADA_IMAGE_TAG"] = run(["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"]).stdout.strip()
    run(["bash", str(REPO_ROOT / "stack/scripts/fixturenet-new"), name], env=env)

    # c4: bring the fixturenet to ready -- the armada-disclosure job proves the pool, the
    # HubCustodian and the adjudicator respond on the fixturenet RPC.
    job_result = run_disclosure_job(dep, env)
    fixturenet_up = bool(job_result.get("fixturenet_up"))

    # snapshot_present: a base-layer snapshot exists for a later warm run (the fixturenet-new
    # cold path builds and snapshots the base layer; the warm path restores it).
    snap_dir = Path(os.environ["HOME"]) / "deployments" / ".snapshots"
    snapshot_present = any(snap_dir.glob("armada-fixturenet-base-*.tar.zst"))

    # harness_files_present: the script exists and a compose job under stack/compose-jobs/
    # refers to it (so the job runs it).
    script_file = REPO_ROOT / "stack/scripts/armada-disclosure-acceptance.py"
    job_refs = [
        f
        for f in (REPO_ROOT / "stack/compose-jobs").glob("*.yml")
        if f.is_file() and "armada-disclosure-acceptance" in f.read_text()
    ]
    harness_files_present = script_file.exists() and len(job_refs) >= 1

    result = {
        "harness_files_present": harness_files_present,
        "fixturenet_up": fixturenet_up,
        "snapshot_present": snapshot_present,
    }
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
