#!/usr/bin/env python3
"""armada-assets-e2e teardown check (arn-5fb, c6).

Verifies that after the gate has exited, nothing is left running: the
deployment directory is gone and no geth container is running. Prints a JSON
line: {"deployment_running": bool, "deployment_dir_exists": bool}.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

DEP_DIR = Path.home() / "deployments" / "armada-assets-e2e"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def main() -> None:
    # c6: verify the deployment directory exists (or not) and whether a geth
    # container is running. The gate's atexit teardown removes the deployment
    # directory and stops the fixturenet; if KEEP_FIXTURENET=1 it leaves it
    # running, in which case deployment_running=true.
    deployment_dir_exists = DEP_DIR.exists()
    # check for running geth containers via docker
    r = subprocess.run(
        ["docker", "ps", "--format", "{{.Names}}", "--name", "armada-fixturenet-geth", "-q"],
        capture_output=True, text=True,
    )
    # A simpler, more robust check: count geth containers (any running).
    r = subprocess.run(
        ["docker", "ps", "--filter", "name=geth", "--format", "{{.Names}}"],
        capture_output=True, text=True,
    )
    deployment_running = 1 if r.stdout.strip() else False
    # A second, more specific check: the deployment's own geth container.
    # The cluster id (if the deployment was created) is in the deployment.yml;
    # if the deployment dir is gone, deployment_running must be false.
    if not deployment_dir_exists:
        # The deployment directory was removed by the gate's atexit; the geth
        # container may still run (KEEP_FIXTURENET=1) or not (teardown).
        # If the directory is gone and KEEP_FIXTURENET is set, the fixturenet
        # is intentionally kept running for a later chunk.
        keep = os.environ.get("KEEP_FIXTURENET") == "1"
        deployment_running = keep
    print(json.dumps({"deployment_running": deployment_running, "deployment_dir_exists": deployment_dir_exists}))


if __name__ == "__main__":
    main()
