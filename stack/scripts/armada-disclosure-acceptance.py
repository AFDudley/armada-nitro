#!/usr/bin/env python3
"""stack/scripts/armada-disclosure-acceptance.py — the selective-disclosure harness acceptance.

Stands up a fresh fixturenet with stack/scripts/fixturenet-new (run-unique name, TMPDIR set
to the repo .scratch) which builds and snapshots the base layer so a later run is warm. The
shared wallet + proof code lives in env/gates/nitro-e2e/prepare.ts (createWallet + the Groth16
prover via lib/sdk/wallet + lib/sdk/prover), reused by the gate stage the harness builds on.

Brings the fixturenet to ready by running the armada-disclosure compose job (run-job, never a
direct host read of the deployment's own data directory -- gates and runners reach the
fixturenet only via run-job and geth RPC): that job runs the selective-disclosure hops H1-H7
as real transactions (shield, depositFromNote, co-signed states, conclude, unshield), records
every transaction and event into a disclosure package, and prints the hop result as a JSON
line, which this script reads back from the job's captured output.

Prints exactly one JSON line to stdout (all diagnostics go to stderr):
    {"hops_ok": true, "eoa2_usdc_delta": <int>, "eoa_distinct": true,
     "payout_note_owned": true, "package_path": "..."}
then tears the fixturenet down and exits 0.
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
REPO_ROOT = SCRIPT.parents[2]  # <home/rix/code/git_puller/repos/armada-nitro/.worktrees/worker-arn-252/stack/scripts/armada-disclosure-acceptance.py -> home/rix/code/git_puller/repos/armada-nitro/.worktrees/worker-arn-252
TMPDIR = REPO_ROOT / ".scratch"  # TMPDIR is set to the repo .scratch
DISCLOSURE_JOB = "armada-disclosure"  # stack/compose-jobs/docker-compose-armada-disclosure.yml


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def run(cmd: list[str], env: dict[str, str] | None = None) -> subprocess:
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


def read_json_line(output: str) -> dict[str, object]:
    """Return the last JSON-parseable line of the job output (the hop result)."""
    parsed: object = {}
    for line in reversed(output.splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            candidate = json.loads(line)
            if isinstance(candidate, dict):
                parsed = candidate
        except json.JSONDecodeError:
            continue
    return parsed


def run_disclosure_job(dep: Path, env: dict[str, str]) -> dict[str, object]:
    """Run the armada-disclosure job -- the sanctioned run-job path, never a direct host read
    of the deployment's own data directory -- which executes the selective-disclosure hops
    H1-H7 as real transactions, writes the disclosure package, and prints the hop result as
    a JSON line. Returns that result (the last JSON-parseable line of the job's captured
    output)."""
    p = run(
        [resolve_laconic_so(), "deployment", "--dir", str(dep), "run-job", DISCLOSURE_JOB],
        env=env,
    )
    return read_json_line(p.stdout)


def teardown(dep: Path, env: dict[str, str]) -> None:
    """Tear the fixturenet down (c6): shut the deployment's containers via laconic-so down."""
    run([resolve_laconic_so(), "deployment", "--dir", str(dep), "down"], env=env)


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

    # c4: bring the fixturenet to ready and execute the selective-disclosure hops H1-H7 as
    # real transactions. The job also writes the disclosure package and prints the hop result
    # as a JSON line (hops_ok, eoa2_usdc_delta, eoa_distinct, payout_note_owned, package_path).
    hop_result = run_disclosure_job(dep, env)

    # c6: tear the fixturenet down after recording the package.
    teardown(dep, env)

    # Report the hop result (the disclosure package + every transaction and event).
    print(json.dumps(hop_result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
