#!/usr/bin/env python3
"""armada-watchtower-e2e gate (E15b) -- thin runner.

The runner does NOT run the scenario itself. It invokes the job `armada-watchtower-e2e` on the
operator-managed fixturenet (E12) via `laconic-so deployment --dir <E12> run-job armada-watchtower-
e2e`, passing the two scenario allocations as environment variables (STATE_N_USER / STATE_N1_USER),
reads the job's single JSON line from the job's stdout, and prints it unchanged.

The job definition (stack/compose-jobs, registered in stack/stacks) does the actual work: builds
two real-proof channel deposits and runs the on-chain watchtower scenario (script/WatchtowerScenario.
s.sol), then prints the JSON line this runner relays.

Usage:
    python3 stack/scripts/armada-watchtower-e2e.py \
        --state-n-allocation-lamports 1000000 --state-n-plus1-allocation-lamports 2000000

Environment overrides:
    ARMADA_STATE_DIR  path to the operator-managed E12 deployment (default ~/deployments/<dir>)
    ARMADA_RPC_URL   geth RPC (default http://127.0.0.1:8545) -- the deployment is reached only
                      through laconic-so run-job and this RPC, never by touching its data files.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys

DEFAULT_DIR = pathlib.Path.home() / "deployments" / "armada-fixturenet-e12"
DEFAULT_RPC = "http://127.0.0.1:8545"
JOB_NAME = "armada-watchtower-e2e"


def deployment_dir() -> pathlib.Path:
    env = os.environ.get("ARMADA_STATE_DIR")
    return pathlib.Path(env) if env else DEFAULT_DIR


def rpc_url() -> str:
    return os.environ.get("ARMADA_RPC_URL", DEFAULT_RPC)


def run_job(state_n_user: int, state_n1_user: int) -> str:
    """Invoke the job and return its single JSON line (printed unchanged by the caller)."""
    e12_dir = deployment_dir()
    if not e12_dir.is_dir():
        print(f"no deployment dir at {e12_dir}", file=sys.stderr)
        raise SystemExit(2)

    env = dict(os.environ)
    env["STATE_N_USER"] = str(state_n_user)
    env["STATE_N1_USER"] = str(state_n1_user)
    env["HUB_RPC"] = rpc_url()

    cmd = ["laconic-so", "deployment", "--dir", str(e12_dir), "run-job", JOB_NAME]
    p = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if p.stderr:
        print(p.stderr, file=sys.stderr, end="" if p.stderr.endswith("\n") else "\n")
    if p.returncode != 0:
        print(f"laconic-so run-job exited {p.returncode}", file=sys.stderr)
        raise SystemExit(p.returncode)

    # The job prints exactly one JSON line to its stdout; laconic-so may frame it, so find the
    # line that parses as the job's JSON (contains scenario_a + scenario_b) and return it.
    for line in p.stdout.splitlines():
        line = line.strip()
        if line.startswith("{") and "scenario_a" in line and "scenario_b" in line:
            try:
                json.loads(line)
            except json.JSONDecodeError:
                continue
            return line
    raise RuntimeError("no JSON line found in laconic-so run-job output")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-n-allocation-lamports", type=int, required=True)
    parser.add_argument("--state-n-plus1-allocation-lamports", type=int, required=True)
    args = parser.parse_args()

    state_n_user = args.state_n_allocation_lamports
    state_n1_user = args.state_n_plus1_allocation_lamports
    if state_n1_user <= state_n_user:
        print("state N+1's allocation must be greater than state N's", file=sys.stderr)
        return 2

    result = run_job(state_n_user, state_n1_user)
    print(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
