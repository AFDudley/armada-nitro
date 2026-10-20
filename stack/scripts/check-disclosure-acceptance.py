#!/usr/bin/env python3
"""c5: After a full run, no fixturenet created by the run is left running or stored.

Runs the acceptance script (a full create + hops + teardown), then verifies the run's fixturenet
is gone: the deployment directory (stored) and any running compose services (running). Prints
`{"leftover_fixturenets": N}`; exits 0 only when N == 0.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Any


def run_acceptance() -> dict[str, Any]:
    p = subprocess.run(
        ["python3", "stack/scripts/armada-disclosure-acceptance.py"],
        capture_output=True,
        text=True,
    )
    if p.stdout:
        print(p.stdout, file=sys.stderr)
    if p.stderr:
        print(p.stderr, file=sys.stderr)
    if p.returncode != 0:
        raise RuntimeError(f"acceptance script failed (exit {p.returncode})")
    # Parse the script's JSON (the last JSON line of stdout).
    for line in p.stdout.strip().splitlines()[::-1]:
        line = line.strip()
        if line.startswith("{"):
            return dict(json.loads(line))
    raise RuntimeError("no JSON line in acceptance script output")


def main() -> int:
    result = run_acceptance()
    name = str(result.get("fixturenet_name", ""))
    dep_dir = os.path.join(os.environ.get("HOME", ""), "deployments", name)
    leftover = 0
    if os.path.exists(dep_dir):
        # Stored fixturenet left over.
        leftover += 1
        # Also check running services for this fixturenet (the script stops them via
        # `laconic-so deployment stop --delete-volumes`; any still-running container is a
        # leftover).
        p = subprocess.run(
            ["laconic-so", "deployment", "--dir", dep_dir, "ps"],
            capture_output=True,
            text=True,
        )
        # Count the running services: parse `docker compose ps` output (lines with a
        # `running` state).
        for line in p.stdout.splitlines():
            if "running" in line.lower():
                leftover += 1
    print(json.dumps({"leftover_fixturenets": leftover}))
    return 0 if leftover == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
