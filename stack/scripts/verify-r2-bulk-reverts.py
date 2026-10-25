#!/usr/bin/env python3
"""stack/scripts/verify-r2-bulk-reverts.py -- R2 scenario (d): the bulk transferAllAssets path
(Safety.lean's bulk_transfer_all_assets_effect, which REPLACES the superseded
bulk_paths_never_succeed -- operator correction, 2026-10-25).

Stands up or restores the fixturenet from the warm snapshot (stack/scripts/fixturenet-new),
runs the R2-bulk-reverts job via run-job (never a direct host read of the deployment's own
data directory), reads the job's JSON result back, tears the fixturenet down on exit, and
prints exactly one JSON line to stdout:
    {"deposit_used_real_proof": true, "bulk_reverted": <bool|null>, "live_note": <bool|null>,
     "held_before": <int|null>, "held_after": <int|null>, "expected_payout": <int|null>,
     "debit_matches": <bool|null>, "stage": <str|null>, "reason": <str|null>,
     "result_reported": true, "result": "PASS"|"FAIL"|"ERROR"}
and exits 0 regardless of the scenario's own result -- this script's own acceptance is that the
scenario ran end to end and reported a result, not that it passed.

The job trials a real-proof depositFromNote funding call first. Today it reverts ("Collateral
not adjudicator-owned": no client can fund a channel on today's contract, the stock railgun SDK
derives a Poseidon-hashed note public key, never a raw address); the scenario reports ERROR with
stage="deposit" and the real decoded reason, before conclude or transferAllAssets ever run.

If funding ever succeeds, the job concludes the channel and trials+asserts the bulk
transferAllAssets call: bulk_transfer_all_assets_effect requires it NOT to revert, and its
effect to match transfer's own per-asset "afford" fold (priority-order payout out of the held
value, docs.statechannels.org/0080:77). Today's deployed contract does not override
transferAllAssets (departures-found.md item 5/8): the call succeeds through
PoolSpend.mintPayoutCommitmentsNoChannel with no pool debit, so once funding is possible the
conservation check here is expected to FAIL, citing item 5/8.
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


def run_job(dep: Path, env: dict[str, str]) -> dict[str, object]:
    """Run the R2-bulk-reverts job -- the sanctioned run-job path, never a host read of the
    deployment's own state -- and return its JSON result (the last JSON-parseable line of its
    captured output)."""
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
    """Guarded teardown on exit (docs/tasks/R2-fixturenet-defect-scenarios.md, "Scenarios"):
    laconic-so deployment stop --delete-volumes, sudo umount the fixturenet's RAM disk
    (fixturenet-new's own pattern -- a bare umount always fails silently on this host), then a
    guarded rm -rf."""
    try:
        run(
            [resolve_laconic_so(), "deployment", "--dir", str(dep), "stop", "--delete-volumes"],
            env=env,
            check=False,
        )
    except Exception as exc:  # pragma: no cover -- best-effort teardown
        log(f"teardown stop failed (continuing): {exc}")
    run(["sudo", "umount", str(dep / "data")], env=env, check=False)
    deployments_root = Path(os.environ["HOME"]) / "deployments"
    try:
        dep_resolved = dep.resolve()
        if dep_resolved.is_relative_to(deployments_root) and dep_resolved != deployments_root:
            shutil.rmtree(dep_resolved, ignore_errors=True)
    except Exception as exc:  # pragma: no cover -- best-effort teardown
        log(f"teardown rm -rf failed (continuing): {exc}")


def main() -> int:
    name = f"r2-bulk-reverts-{int(time.time())}-{uuid.uuid4().hex[:6]}"
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
        job_result = run_job(dep, env)
    finally:
        teardown(dep, env)

    result = {
        "deposit_used_real_proof": bool(job_result.get("deposit_used_real_proof")),
        "bulk_reverted": job_result.get("bulk_reverted"),
        "live_note": job_result.get("live_note"),
        "held_before": job_result.get("held_before"),
        "held_after": job_result.get("held_after"),
        "expected_payout": job_result.get("expected_payout"),
        "debit_matches": job_result.get("debit_matches"),
        "stage": job_result.get("stage"),
        "reason": job_result.get("reason"),
        "result_reported": job_result.get("result") in ("PASS", "FAIL", "ERROR"),
        "result": job_result.get("result"),
    }
    if result["result"] == "FAIL":
        # Expected once funding is possible: departures-found.md item 5/8 -- today's deployed
        # contract does not override transferAllAssets/concludeAndTransferAllAssets, so the
        # inherited call succeeds through PoolSpend.mintPayoutCommitmentsNoChannel with no pool
        # debit, not bulk_transfer_all_assets_effect's own afford-based fold.
        log("FAIL: cited cause: departures-found.md item 5/8 (no pool debit in the bulk path)")
    elif result["result"] == "ERROR":
        # The scenario stopped before the bulk call is reachable at all: the funding deposit
        # itself reverts on today's contract (no client can fund a channel).
        log(f"ERROR: stopped at stage={result['stage']!r}, reason={result['reason']!r}")

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
