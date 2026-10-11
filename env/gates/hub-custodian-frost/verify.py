#!/usr/bin/env python3
"""armada-custodian-frost gate (arn-8e9).

Thin runner over the laconic-so job: delegates to the shared job helper
(scripts/armada_job_helper.py, arn-895), which builds the job's image from this checkout's
committed content if it is missing, selects it (ARMADA_IMAGE_TAG via laconic-so's "deploy
create --update" -- this also syncs the deployment's compose + compose-jobs, preserving
data/ volumes and config.env), and calls "laconic-so deployment --dir <deployment> run-job".
This prints the job's one-line JSON output unchanged. The check logic lives in the job (env
image), so no host process reads or writes the deployment's root-only data directory.

Usage:
    python3 env/gates/hub-custodian-frost/verify.py match
    python3 env/gates/hub-custodian-frost/verify.py mismatch
"""

import json
import os
import pathlib
import sys
from typing import Any

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(_REPO_ROOT / "scripts"))
from armada_job_helper import run_job as _helper_run_job  # noqa: E402

JOB = "armada-custodian-frost"


def _dep_dir() -> pathlib.Path:
    env = os.environ.get("ARMADA_DEPLOYMENT_DIR")
    if env:
        return pathlib.Path(env)
    return pathlib.Path.home() / "deployments" / "armada-fixturenet-e12"


def _run_check_job(case: str) -> str:
    """Run the check job through the shared helper (which builds/selects the job's
    HEAD-sha image and syncs the deployment first) and return its stdout (which carries
    the job's JSON line plus the orchestrator's own "Running job" chatter)."""
    extra_env = {"CUSTODIAN_FROST_CASE": case, "ARMADA_IMAGE_DEP_DIR": str(_dep_dir())}
    stdout, _returncode = _helper_run_job(JOB, extra_env=extra_env)
    return stdout


def _extract_json(output: str) -> str:
    """Extract the job's single JSON line from the job's stdout (which also
    carries the orchestrator's "Running job" line and docker/compose chatter)."""
    data = output
    dec = json.JSONDecoder()
    idx = data.rfind("{")
    while idx != -1:
        try:
            obj, _ = dec.raw_decode(data, idx)
            return json.dumps(obj)
        except ValueError:
            idx = data.rfind("{", 0, idx)
    return ""


def _case_passed(case: str, report: dict[str, Any]) -> bool:
    """Whether the case behaved as the gate expects (mirrors the old host-process
    verify.py's exit code): match wants the positive case to pass; mismatch wants
    the negative case to correctly fail and name both values."""
    if case == "match":
        return bool(report.get("overall_positive_case_passed"))
    return report.get("verify_exit_code", 0) != 0 and bool(report.get("failure_names_mismatch"))


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: verify.py {match|mismatch}", file=sys.stderr)
        return 2
    case = argv[0]
    if case not in ("match", "mismatch"):
        print(f"unknown case: {case}", file=sys.stderr)
        return 2
    # The shared helper syncs the deployment's job files (via deploy create --update)
    # before running the check job.
    output = _run_check_job(case)
    json_line = _extract_json(output)
    if not json_line:
        print("verify.py: no JSON line in job output; full output:", file=sys.stderr)
        print(output, file=sys.stderr)
        return 1
    print(json_line)
    return 0 if _case_passed(case, json.loads(json_line)) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
