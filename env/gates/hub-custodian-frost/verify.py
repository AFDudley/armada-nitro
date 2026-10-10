#!/usr/bin/env python3
"""armada-custodian-frost gate (arn-8e9).

Thin runner over the laconic-so job: first syncs the deployment's job files with
laconic-so's "deploy create --update" (the same step scripts/run-armada-watchtower-scenario.sh
takes), then runs the check job through "laconic-so deployment --dir <deployment> run-job" and
prints the job's one-line JSON output unchanged. The check logic lives in the job (env image),
so no host process reads or writes the deployment's root-only data directory.

Usage:
    python3 env/gates/hub-custodian-frost/verify.py match
    python3 env/gates/hub-custodian-frost/verify.py mismatch
"""

import json
import os
import pathlib
import subprocess
import sys
from typing import Any

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]

LAONIC_SO = os.environ.get("LACONIC_SO") or "/home/rix/bin/laconic-so"
PYTHON = os.environ.get("LACONIC_SO_PYTHON") or "/usr/bin/python3.12"
STACK_DIR = _REPO_ROOT / "stack" / "stacks" / "armada-nitro-fixturenet"


def _dep_dir() -> pathlib.Path:
    env = os.environ.get("ARMADA_DEPLOYMENT_DIR")
    if env:
        return pathlib.Path(env)
    return pathlib.Path.home() / "deployments" / "armada-fixturenet-e12"


def _sync_deployment() -> None:
    """Sync the deployment's job files with the stack (the same step
    scripts/run-armada-watchtower-scenario.sh does): laconic-so's "deploy create --update"
    regenerates the compose + compose-jobs, preserving data/ volumes and config.env."""
    dep = _dep_dir()
    spec_file = dep.parent / f"{dep.name}-spec.yml"
    cmd = [
        PYTHON,
        LAONIC_SO,
        "--stack",
        str(STACK_DIR),
        "deploy",
        "create",
        "--spec-file",
        str(spec_file),
        "--deployment-dir",
        str(dep),
        "--update",
    ]
    subprocess.run(cmd, capture_output=True, text=True)


def _run_check_job(case: str) -> str:
    """Run the check job through laconic-so and return its stdout (which carries
    the job's JSON line plus the orchestrator's own "Running job" chatter)."""
    cmd = [
        PYTHON,
        LAONIC_SO,
        "deployment",
        "--dir",
        str(_dep_dir()),
        "run-job",
        "armada-custodian-frost",
    ]
    env = {**os.environ, "CUSTODIAN_FROST_CASE": case}
    proc = subprocess.run(cmd, env=env, capture_output=True, text=True)
    return proc.stdout


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
    # Sync the deployment's job files first (the --update step), then run the check job.
    _sync_deployment()
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
