#!/usr/bin/env python3
"""check-e2e-builds-own-fixturenet.py (arn-e7a c6/c9).

Clause c9: a full e2e run builds a brand-new fixturenet from the tree under
test, runs the e2e jobs on it, and the shared fixturenet
(~/deployments/armada-fixturenet-e12) keeps running before and after, without
interruption.

This oracle proves exactly that clause and nothing else. It does NOT require any
e2e job to exit 0 -- job success is a separate deliverable (for armada-nitro-e2e
it is arn-b27). It proves the job RAN ON the own deployment: the job container
attaches to the own deployment's compose network `<cluster>_default` and reaches
the own geth by the compose service name, never the host network.

Prints one JSON object:
  {"shared_running_before": bool, "own_fixturenet_built": bool,
   "shared_running_after": bool}
The acceptance oracle asserts all three are True.

own_fixturenet_built is True only when all of these hold:
  - stack/scripts/fixturenet-new built the own deployment (or it was already up),
  - the own geth container is up, and
  - one e2e job (armada-nitro-e2e) ran on the own deployment attached to the own
    compose network `<cluster>_default`, not the host network.

No arbitrary build timeout: a cold build is minutes long, and the spec-level
timeout_seconds bounds the whole oracle. A later oracle reuses this one build
(build_or_reuse returns the running deployment untouched).
"""

import json
import os
import pathlib
import subprocess
import sys
import threading
import time

_SHARED = pathlib.Path.home() / "deployments" / "armada-fixturenet-e12"
_PROBE_JOB = "armada-nitro-e2e"


def _cluster_id(dep: pathlib.Path) -> str:
    """The laconic cluster-id for a deployment (from deployment.yml)."""
    yml = dep / "deployment.yml"
    if not yml.exists():
        return ""
    for line in yml.read_text().splitlines():
        if line.startswith("cluster-id:"):
            return line.split(":", 1)[1].strip()
    return ""


def _container_up(name: str) -> bool:
    r = subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True)
    return r.returncode == 0 and name in r.stdout.splitlines()


def _dep_running(dep: pathlib.Path) -> bool:
    """A deployment is running when its geth container is up on the host."""
    cluster = _cluster_id(dep)
    return bool(cluster) and _container_up(f"{cluster}-armada-fixturenet-geth-1")


def _own_name() -> str:
    head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    return os.environ.get("E2E_FIXTURENET_NAME", f"armada-fixturenet-e2e-{head}")


def _build_or_reuse(name: str) -> tuple[pathlib.Path, bool]:
    """Build the own fixturenet from the tree under test, or reuse it when it is
    already running (so a sibling oracle does not rebuild it). The build's own
    output goes to stderr so this oracle's stdout stays pure JSON."""
    dep = pathlib.Path.home() / "deployments" / name
    if dep.exists() and _dep_running(dep):
        return dep, True
    r = subprocess.run(["bash", "stack/scripts/fixturenet-new", name], capture_output=True, text=True)
    sys.stderr.write(r.stdout)
    sys.stderr.write(r.stderr)
    return dep, (r.returncode == 0 and _dep_running(dep))


def _job_ran_on_own(dep: pathlib.Path, cluster: str) -> bool:
    """Run one e2e job on the own deployment and confirm two things: its container
    attached to the own compose network `<cluster>_default` (not the host
    network), and it reached the own geth by the compose service name
    `armada-fixturenet-geth:8545`. The job's own exit code is NOT required: the
    job may still fail later on contract logic (for armada-nitro-e2e that is
    arn-b27), but by then it has already run on the own fixturenet's chain."""
    os.environ["ARMADA_IMAGE_DEP_DIR"] = str(dep)
    sys.path.insert(0, "scripts")
    from armada_job_helper import run_job

    state: dict[str, object] = {"done": False, "out": ""}

    def _run() -> None:
        try:
            out, _ = run_job(_PROBE_JOB)
            state["out"] = out
        finally:
            state["done"] = True

    t = threading.Thread(target=_run, daemon=True)
    t.start()

    own_net = f"{cluster}_default"
    attached = False
    host_net = False
    seen = False
    # Poll for the job container while the job runs. The job runs its stages in
    # one container for a while, so one inspection is enough.
    while not state["done"] and not seen:
        ps = subprocess.run(
            [
                "docker",
                "ps",
                "--filter",
                f"label=com.docker.compose.project={cluster}",
                "--filter",
                f"label=com.docker.compose.service={_PROBE_JOB}",
                "--format",
                "{{.Names}}",
            ],
            capture_output=True,
            text=True,
        )
        names = [n for n in ps.stdout.splitlines() if n.strip()]
        if names:
            seen = True
            insp = subprocess.run(
                ["docker", "inspect", "-f", "{{json .NetworkSettings.Networks}}", names[0]],
                capture_output=True,
                text=True,
            )
            try:
                nets = json.loads(insp.stdout or "{}")
            except json.JSONDecodeError:
                nets = {}
            attached = own_net in nets
            host_net = "host" in nets
            break
        time.sleep(0.2)

    t.join()
    # The job's SDK prints the RPC it loaded. On the branch it reads HUB_RPC and
    # reaches the own geth by the service name. On the base tree the SDK is
    # hardcoded to localhost, which a bridge-networked job cannot reach.
    reached_own_geth = "armada-fixturenet-geth:8545" in str(state["out"])
    return seen and attached and not host_net and reached_own_geth


def main() -> int:
    shared_before = _dep_running(_SHARED)

    name = _own_name()
    dep, built = _build_or_reuse(name)

    own_built = False
    if built:
        cluster = _cluster_id(dep)
        own_built = bool(cluster) and _job_ran_on_own(dep, cluster)

    shared_after = _dep_running(_SHARED)

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
