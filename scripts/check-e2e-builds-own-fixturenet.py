#!/usr/bin/env python3
"""check-e2e-builds-own-fixturenet.py (arn-e7a c6): a full e2e run builds its own
fixturenet from the tree under test and runs the e2e jobs on it, while the shared
fixturenet (~/deployments/armada-fixturenet-e12) keeps running before and after.

Prints one JSON object:
  {"shared_running_before": bool, "own_fixturenet_built": bool, "shared_running_after": bool}
The acceptance oracle asserts all three are True.
"""

import json
import os
import pathlib
import subprocess
import sys

_SHARED = pathlib.Path.home() / "deployments" / "armada-fixturenet-e12"


def _get_cluster_id(dep_dir: pathlib.Path) -> str:
    """The laconic cluster-id for a deployment (from deployment.yml)."""
    yml = dep_dir / "deployment.yml"
    if not yml.exists():
        return ""
    cluster = None
    for line in yml.read_text().splitlines():
        if line.startswith("cluster-id:"):
            cluster = line.split(":", 1)[1].strip()
            break
    return cluster or ""


def dep_running(dep_dir: pathlib.Path) -> bool:
    """A deployment is 'running' when its geth container is up on the host (c6)."""
    cluster = _get_cluster_id(dep_dir)
    if not cluster:
        return False
    r = subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True)
    if r.returncode != 0:
        return False
    needle = f"{cluster}-armada-fixturenet-geth-1"
    return needle in r.stdout


def main() -> int:
    # 1. Is the shared fixturenet running before the e2e run? (c6: still running)
    shared_before = dep_running(_SHARED)

    # 2. Build the e2e run's own fixturenet from the tree under test (c6).
    head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    name = os.environ.get("E2E_FIXTURENET_NAME", f"armada-fixturenet-e2e-{head}")
    dep_dir = pathlib.Path.home() / "deployments" / name
    r = subprocess.run(
        ["bash", "stack/scripts/fixturenet-new", name], capture_output=True, text=True, timeout=1500
    )
    own_built = (r.returncode == 0) and dep_dir.exists()

    # 3. Run the e2e jobs on the own fixturenet (c3/c4/c7). The job reaches geth by
    # the compose service name (c4), never the shared fixturenet (c7).
    os.environ["ARMADA_IMAGE_DEP_DIR"] = str(dep_dir)
    sys.path.insert(0, "scripts")
    from armada_job_helper import run_job

    if own_built:
        for job in ["armada-nitro-e2e", "armada-custodian-e2e", "armada-watchtower-e2e"]:
            _, rc = run_job(job)
            if rc != 0:
                own_built = False

    # 4. Is the shared fixturenet still running after the run? (c6: no interruption)
    shared_after = dep_running(_SHARED)

    print(
        json.dumps(
            {
                "shared_running_before": shared_before,
                "own_fixturenet_built": own_built,
                "shared_running_after": shared_after,
            }
        )
    )
    return 0 if (shared_before and own_built and shared_after) else 1


if __name__ == "__main__":
    sys.exit(main())
