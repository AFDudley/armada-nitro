#!/usr/bin/env python3
"""stack/scripts/verify-r2-payout.py -- R2 scenario (a) acceptance
(docs/tasks/R2-fixturenet-defect-scenarios.md): "a payout succeeds with a live note".

Stands up a fresh fixturenet with stack/scripts/fixturenet-new (run-unique name, TMPDIR set to
the repo .scratch, same as armada-disclosure-acceptance.py), which restores the cached base
layer when the key matches or builds + snapshots it otherwise. Runs the r2-payout compose job
(stack/compose-jobs/docker-compose-R2-payout.yml) via run-job -- never a direct host read of the
deployment's own data directory, gates and runners reach the fixturenet only via run-job and
RPC. That job funds a channel with a real-proof depositFromNote (env/gates/nitro-e2e/prepare.ts's
shared wallet + Groth16 prover), concludes it (unanimous conclude), trials and (if it does not
revert) broadcasts the payout transfer call, and checks the recipient's note is live in the pool
(PrivacyPool.isLive) -- script/FixturenetR2Payout.s.sol. The job also reads the pool's own
testingMode() and checks VERIFICATION_BYPASS is unset.

Runs on a real fixturenet, real proofs, no VERIFICATION_BYPASS (c2). Not part of the
commit-boundary gate (.pre-commit-config.yaml) -- a standalone, by-hand or by-schedule run,
since it is expected FAIL until the adjudicator rewrite lands (departure item 6: see below).

Prints exactly one JSON line to stdout (all diagnostics go to stderr):
    {"testing_mode": false, "verification_bypass": false, "deposit_used_real_proof": true,
     "transfer_amount_nonzero": true, "payout_reverted": <bool>, "live_note": <bool>,
     "result_reported": true, "result": "PASS"|"FAIL"}
and exits 0 regardless of whether the scenario itself reports PASS or FAIL -- this script's own
acceptance is that the scenario ran end to end and reported a result (docs/tasks/
R2-fixturenet-defect-scenarios.md, "Acceptance"), not that it passed. When the scenario reports
FAIL, the reason is departures-found.md item 6 (PoolSpend.mintOwnedCommitments submits a
hard-coded zero Groth16 proof to transactOwned; PrivacyPool.verifyOwned rejects it under real
verification), the only way this scenario fails today.

Tears the fixturenet down on exit with a guarded `laconic-so deployment stop --delete-volumes`
then a guarded `rm -rf` (docs/tasks/R2-fixturenet-defect-scenarios.md, "Scenarios").
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
TMPDIR = REPO_ROOT / ".scratch"  # TMPDIR is set to the repo .scratch
PAYOUT_JOB = "R2-payout"  # stack/compose-jobs/docker-compose-R2-payout.yml


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


def run_payout_job(dep: Path, env: dict[str, str]) -> dict[str, object]:
    """Run the r2-payout job -- the sanctioned run-job path, never a host read of the
    deployment's own state -- which performs the real-proof deposit, conclude, payout transfer
    and live-note check, and returns its JSON result (the last JSON-parseable line of its
    captured output)."""
    p = run(
        [resolve_laconic_so(), "deployment", "--dir", str(dep), "run-job", PAYOUT_JOB],
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
    raise RuntimeError(f"{PAYOUT_JOB} job printed no scenario-result JSON line (exit {p.returncode})")


def teardown(dep: Path, env: dict[str, str]) -> None:
    """Guarded teardown on exit (docs/tasks/R2-fixturenet-defect-scenarios.md, "Scenarios"):
    `laconic-so deployment stop --delete-volumes`, then a guarded `rm -rf` of the deployment
    directory. Never removes anything unless `dep` is a real, non-empty path under
    ~/deployments, mirroring the brief's `: "${DEP:?}"` guard."""
    if not dep or str(dep) in ("", "/", str(Path(os.environ.get("HOME", "/")))):
        log(f"refusing to tear down suspicious deployment path: {dep!r}")
        return
    try:
        run(
            [resolve_laconic_so(), "deployment", "--dir", str(dep), "stop", "--delete-volumes"],
            env=env,
            check=False,
        )
    except Exception as exc:  # pragma: no cover -- best-effort teardown
        log(f"teardown stop failed (continuing): {exc}")
    deployments_root = Path(os.environ["HOME"]) / "deployments"
    try:
        dep_resolved = dep.resolve()
        if dep_resolved.is_relative_to(deployments_root) and dep_resolved != deployments_root:
            shutil.rmtree(dep_resolved, ignore_errors=True)
    except Exception as exc:  # pragma: no cover -- best-effort teardown
        log(f"teardown rm -rf failed (continuing): {exc}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--json",
        action="store_true",
        help="print the result as a single JSON line (the only supported output format)",
    )
    parser.parse_args()

    name = f"r2-payout-{int(time.time())}-{uuid.uuid4().hex[:6]}"
    dep = Path(os.environ["HOME"]) / "deployments" / name

    env = os.environ.copy()
    # c2: real proofs, no VERIFICATION_BYPASS -- this script never sets it, and strips it from
    # the environment it hands to every subprocess so an operator's stray export cannot leak in.
    env.pop("VERIFICATION_BYPASS", None)

    TMPDIR.mkdir(exist_ok=True)
    env["TMPDIR"] = str(TMPDIR)
    env["ARMADA_IMAGE_TAG"] = run(["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"]).stdout.strip()

    try:
        run(["bash", str(REPO_ROOT / "stack/scripts/fixturenet-new"), name], env=env)
        job_result = run_payout_job(dep, env)
    finally:
        teardown(dep, env)

    result = {
        "testing_mode": bool(job_result.get("testing_mode")),
        "verification_bypass": bool(job_result.get("verification_bypass")),
        "deposit_used_real_proof": bool(job_result.get("deposit_used_real_proof")),
        "transfer_amount_nonzero": bool(job_result.get("transfer_amount_nonzero")),
        "payout_reverted": bool(job_result.get("payout_reverted")),
        "live_note": bool(job_result.get("live_note")),
        "result_reported": job_result.get("result") in ("PASS", "FAIL"),
        "result": job_result.get("result"),
    }
    if result["result"] == "FAIL":
        # Expected today (docs/tasks/R2-fixturenet-defect-scenarios.md, "Goal"): departures-found.md
        # item 6 -- PoolSpend.mintOwnedCommitments submits a hard-coded zero Groth16 proof to
        # transactOwned; PrivacyPool.verifyOwned rejects it under real verification, so the payout
        # transfer call reverts. Passes once the adjudicator rewrite lands.
        log("FAIL: cited cause: departures-found.md item 6 (zero Groth16 proof in mintOwnedCommitments)")

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
