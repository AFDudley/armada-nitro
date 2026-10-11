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
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import armada_job_helper  # noqa: E402

# REAL_RPC is resolved inside the job container to the compose service DNS name; no override
# needed from the host runner.
JOB = "armada-watchtower-discrimination-e2e"


def _run_job(scenario: str) -> str:
    """Run the discrimination job on the deployment and return its single JSON line.

    Goes through the shared helper (scripts/armada_job_helper.py, arn-895): it builds
    the HEAD-sha image if missing, syncs the deployment, and runs the job with
    ARMADA_IMAGE_TAG set to HEAD's sha."""
    stdout, rc = armada_job_helper.run_job(JOB, {"SCENARIO": scenario})
    if rc != 0:
        sys.stderr.write(f"run-job {JOB} exited {rc}\n")
        raise SystemExit(rc if rc > 0 else 1)
    p_stdout = stdout
    # The job prints its JSON line to stdout. The line starts with '{' and contains the
    # scenario field.
    for line in p_stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                json.loads(line)
                return line
            except json.JSONDecodeError:
                continue
    # The JSON object can land on the same physical line as preceding chatter, so find the
    # rightmost '{' that parses as JSON.
    data = p_stdout
    dec = json.JSONDecoder()
    idx = data.rfind("{")
    while idx != -1:
        try:
            obj, _ = dec.raw_decode(data, idx)
            return json.dumps(obj)
        except ValueError:
            idx = data.rfind("{", 0, idx)
    raise RuntimeError("no JSON line found in laconic-so run-job output")
