#!/usr/bin/env python3
"""armada-disclosure-acceptance (arn-2fd): the selective-disclosure chain-of-custody acceptance.

Runs stack/scripts/fixturenet-new under a run-unique name (TMPDIR set to the repo's .scratch),
runs the armada-disclosure-acceptance job through `laconic-so deployment run-job` -- which
executes hops H1, H2, H4, H5, H6 and H7 of docs/tasks/16-selective-disclosure.md as real
transactions on that fixturenet and prints the written disclosure package on its own stdout --
writes that package to the repo's .scratch, tears the fixturenet down with
`fixturenet-new --teardown`, and prints one JSON line:

    {"hops_ok": bool, "eoa2_usdc_delta": int, "eoa_distinct": bool,
     "payout_note_owned": bool, "package_path": "<path>"}

Reaches the fixturenet only through `run-job` and RPC (gate-no-host-deployment-access): never
reads the deployment's own /env volume from the host, so the job itself prints the package
through its stdout rather than this script reading the deployment's data directory.

Builds its own fresh fixturenet (stack/scripts/fixturenet-new), never a pre-existing shared one.
Changes no pool contract, no disclosure circuit and no adjudicator contract.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRATCH_DIR = os.path.join(REPO_ROOT, ".scratch")


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def run(
    cmd: list[str], env: dict[str, str] | None = None, check: bool = True
) -> "subprocess.CompletedProcess[str]":
    log("+ " + " ".join(cmd))
    p = subprocess.run(cmd, cwd=REPO_ROOT, env=env, capture_output=True, text=True)
    if p.stdout:
        log(p.stdout)
    if p.stderr:
        log(p.stderr)
    if check and p.returncode != 0:
        raise RuntimeError(f"command failed (exit {p.returncode}): {' '.join(cmd)}")
    return p


def main() -> int:
    os.makedirs(SCRATCH_DIR, exist_ok=True)
    # TMPDIR set to the repo's .scratch: every subprocess this script launches (fixturenet-new,
    # laconic-so, docker) inherits it, so no scratch state from this run lands outside the repo.
    env = dict(os.environ)
    env["TMPDIR"] = SCRATCH_DIR

    head = run(["git", "rev-parse", "HEAD"], env=env).stdout.strip()
    env["ARMADA_IMAGE_TAG"] = head
    laconic = env.get("LACONIC_SO") or "laconic-so"

    # A name unique to this run: fixturenet-new creates ~/deployments/<name>, never a
    # pre-existing shared fixturenet.
    name = f"armada-disclosure-acceptance-{int(time.time())}-{os.getpid()}"
    dep = os.path.expanduser(f"~/deployments/{name}")

    result: dict[str, object] = {}
    try:
        run(["stack/scripts/fixturenet-new", name], env=env)

        p = run([laconic, "deployment", "--dir", dep, "run-job", "armada-disclosure-acceptance"], env=env)
        summary = None
        for line in reversed(p.stdout.strip().splitlines()):
            try:
                summary = json.loads(line)
                break
            except json.JSONDecodeError:
                continue
        if summary is None:
            raise RuntimeError("no JSON line found in armada-disclosure-acceptance job stdout")

        # The job printed the full disclosure package on its own stdout (never read from the
        # deployment's /env volume on the host); write it to the repo's .scratch.
        package_path = os.path.join(SCRATCH_DIR, f"{name}-package.json")
        with open(package_path, "w") as f:
            json.dump(summary["package"], f, indent=2)

        result = {
            "hops_ok": bool(summary["hops_ok"]),
            "eoa2_usdc_delta": int(summary["eoa2_usdc_delta"]),
            "eoa_distinct": bool(summary["eoa_distinct"]),
            "payout_note_owned": bool(summary["payout_note_owned"]),
            "package_path": package_path,
        }
    finally:
        # Tear the fixturenet down -- the same run that created it.
        run(["stack/scripts/fixturenet-new", "--teardown", name], env=env, check=False)

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
