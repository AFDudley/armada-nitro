#!/usr/bin/env python3
"""Shared helper for the E15c discrimination scripts.

Syncs the operator-managed fixturenet (E12) deployment (registering the
`armada-watchtower-discrimination-e2e` job), then runs the job via laconic-so, and
extracts the job's single JSON line.

The host runner only calls 'laconic-so deployment run-job' (after syncing first with
laconic-so's 'deploy create --update', as scripts/run-armada-watchtower-scenario.sh does)
and reads its JSON output. It never stops/deletes/recreates the deployment (the operator
owns the chain and resets it between chunks).
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys

# The operator-managed fixturenet deployment (E12).
DEFAULT_DEP_DIR = pathlib.Path(
    os.environ.get("ARMADA_STATE_DIR", pathlib.Path.home() / "deployments" / "armada-fixturenet-e12")
)

# Alias used by _sync_deployment / _run_job.
DEP_DIR = DEFAULT_DEP_DIR
# REAL_RPC is resolved inside the job container to the compose service DNS name; no override
# needed from the host runner.
JOB = "armada-watchtower-discrimination-e2e"
REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent


def _python312() -> str:
    env = os.environ.get("ARMADA_PYTHON", "python3.12")
    return env


def _laconic_so() -> str:
    return "/home/rix/bin/laconic-so"


def _sync_deployment() -> None:
    """Sync the deployment's generated files (compose, compose-jobs) with this checkout's
    stack, so the new job definition takes effect (idempotent)."""
    spec_file = DEP_DIR / "spec.yml"
    if not spec_file.is_file():
        sys.stderr.write(f"no spec file at {spec_file}\n")
        raise SystemExit(2)
    # The sync is idempotent; it rewrites each job's volumes for the deployment and leaves
    # data/ and config.env alone.
    cmd = [
        _python312(),
        _laconic_so(),
        "--stack",
        "stack/stacks/armada-nitro-fixturenet",
        "deploy",
        "create",
        "--spec-file",
        str(spec_file),
        "--deployment-dir",
        str(DEP_DIR),
        "--update",
    ]
    p = subprocess.run(cmd, cwd=str(REPO_ROOT), capture_output=True, text=True)
    if p.returncode != 0:
        sys.stderr.write(f"laconic-so sync failed (exit {p.returncode})\n{p.stderr}\n")
        raise SystemExit(p.returncode)


def _run_job(scenario: str) -> str:
    """Run the discrimination job on the deployment and return its single JSON line."""
    _sync_deployment()
    cmd = [
        _python312(),
        _laconic_so(),
        "deployment",
        "--dir",
        str(DEP_DIR),
        "run-job",
        JOB,
    ]
    env = dict(os.environ)
    env["SCENARIO"] = scenario
    p = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if p.returncode != 0:
        sys.stderr.write(p.stderr)
        raise SystemExit(p.returncode)
    # The job prints its JSON line to stdout. The line starts with '{' and contains the
    # scenario field.
    for line in p.stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                json.loads(line)
                return line
            except json.JSONDecodeError:
                continue
    # The JSON object can land on the same physical line as preceding chatter, so find the
    # rightmost '{' that parses as JSON.
    data = p.stdout
    dec = json.JSONDecoder()
    idx = data.rfind("{")
    while idx != -1:
        try:
            obj, _ = dec.raw_decode(data, idx)
            return json.dumps(obj)
        except ValueError:
            idx = data.rfind("{", 0, idx)
    raise RuntimeError("no JSON line found in laconic-so run-job output")
