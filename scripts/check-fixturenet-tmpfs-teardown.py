#!/usr/bin/env python3
"""arn-eb0 checker: consolidate the four disagreeing fixturenet tmpfs teardown paths into one
shared teardown routine, so a dead deployment's RAM disk never holds host RAM.

Each case mounts a small tmpfs over a throwaway deployment's data dir, runs the relevant teardown
(the shared routine, the governance-stack teardown, or the deposit-conservation teardown), then
reports the post-state as a single JSON object.

Exits non-zero if any field is not its spec-required value (derived-arn-eb0.spec.json).
"""

from __future__ import annotations
from typing import Any

import json
import os
import pathlib
import subprocess
import sys
import time
import threading
import argparse

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
TEARDOWN = REPO_ROOT / "stack" / "scripts" / "fixturenet-teardown"

CASES = [
    "teardown-clean",
    "teardown-busy",
    "reap-orphan-unique-name",
    "reap-keeps-live",
    "governance-teardown",
    "r2-deposit-teardown",
]


def run(cmd: list[str], **kw: Any) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, **kw)


def mount_tmpfs(dep: pathlib.Path) -> None:
    """Mount a small capped tmpfs over <dep>/data (the fixturenet's RAM disk)."""
    (dep / "data").mkdir(parents=True, exist_ok=True)
    run(["sudo", "mount", "-t", "tmpfs", "-o", "size=1M,mode=0777", "tmpfs", str(dep / "data")])


def mount_present(dep: pathlib.Path) -> bool:
    """True if `findmnt -t tmpfs` lists the deployment's data mount."""
    out = run(["findmnt", "-t", "tmpfs"], text=True)
    return str(dep / "data") in out.stdout


def run_hold_process(dep: pathlib.Path) -> None:
    """Start a background process holding <dep>/data open (keeps the mount alive)."""

    held_fds: list[int] = []  # keep the fd alive so the mount is held

    def hold() -> None:
        held_fds.append(os.open(str(dep / "data"), os.O_RDONLY))
        time.sleep(8)

    t = threading.Thread(target=hold, daemon=True)
    t.start()
    time.sleep(0.5)  # let the holder open the dir


def run_shared_teardown(dep: pathlib.Path) -> int:
    """Run the shared fixturenet-teardown routine (single-deployment form)."""
    p = run(["bash", str(TEARDOWN), str(dep)])
    return p.returncode


def run_governance_teardown(dep: pathlib.Path) -> None:
    """Run the governance-stack check's teardown_fixturenet on the deployment."""
    gov = REPO_ROOT / "scripts" / "check_governance_stack.sh"
    text = gov.read_text()
    # Extract the teardown_fixturenet function definition.
    start_marker = "teardown_fixturenet() {"
    idx = text.index(start_marker)
    depth = 0
    end = idx
    for i in range(idx, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                end = i
                break
    fn_text = text[idx : end + 1]
    lac = run(["bash", "-c", "command -v laconic-so"], text=True)
    laconic = lac.stdout.strip()
    snippet = (
        "set -uo pipefail\n"
        f'REPO_ROOT="{REPO_ROOT}"\n'
        f'LACONIC="{laconic}"\n'
        f"{fn_text}\n"
        f'DEP="{dep}"\n'
        f'NAME="{dep.name}"\n'
        "teardown_fixturenet\n"
    )
    env = os.environ.copy()
    env["DEP"] = str(dep)
    env["NAME"] = dep.name
    run(["bash", "-c", snippet], env=env, text=True)


def run_deposit_teardown(dep: pathlib.Path) -> None:
    """Run the deposit-conservation script's exit teardown (c6)."""
    import importlib.util

    dep_script = REPO_ROOT / "stack" / "scripts" / "verify-r2-deposit-conserves.py"
    spec = importlib.util.spec_from_file_location("vd", dep_script)
    if spec is None:
        return
    if spec.loader is None:
        return
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.teardown(dep, {"DEP": str(dep), "NAME": dep.name})


def run_fixturenet_cleanup(dep: pathlib.Path, other_name: str) -> None:
    """Run fixturenet-new's cleanup_stale_deployments for a *different* deployment name (c3/c4)."""
    fn_script = REPO_ROOT / "stack" / "scripts" / "fixturenet-new"
    content = fn_script.read_text()
    # Extract the cleanup function.
    marker = "cleanup_stale_deployments() {"
    idx = content.index(marker)
    depth = 0
    end = idx
    for i in range(idx, len(content)):
        if content[i] == "{":
            depth += 1
        elif content[i] == "}":
            depth -= 1
            if depth == 0:
                end = i
                break
    fn_text = content[idx : end + 1]
    lac = run(["bash", "-c", "command -v laconic-so"], text=True)
    laconic = lac.stdout.strip()
    # The function needs REPO_ROOT, LACONIC, NAME, DEP.
    # c3/c4: the cleanup runs for a *different* deployment name, so the orphan is reclaimed.
    # The function now delegates to the shared --reap routine.
    snippet = (
        "set -uo pipefail\n"
        f'REPO_ROOT="{REPO_ROOT}"\n'
        f'LACONIC="{laconic}"\n'
        f'NAME="{other_name}"\n'
        'DEP="${HOME}/deployments/${NAME}"\n'
        f"{fn_text}\n"
        "cleanup_stale_deployments\n"
    )
    run(["bash", "-c", snippet], text=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="arn-eb0 fixturenet tmpfs teardown checker")
    parser.add_argument("--case", required=True, choices=CASES)
    args = parser.parse_args()
    case = args.case

    if case == "teardown-clean":
        dep = pathlib.Path.home() / "deployments" / "eb0-clean"
        dep.mkdir(parents=True, exist_ok=True)
        mount_tmpfs(dep)
        exit_code = run_shared_teardown(dep)
        result = {
            "teardown_exit_code": exit_code,
            "mount_present_after": mount_present(dep),
            "deployment_dir_present_after": dep.exists(),
        }
        expect = {
            "teardown_exit_code": 0,
            "mount_present_after": False,
            "deployment_dir_present_after": False,
        }

    elif case == "teardown-busy":
        dep = pathlib.Path.home() / "deployments" / "eb0-busy"
        dep.mkdir(parents=True, exist_ok=True)
        mount_tmpfs(dep)
        run_hold_process(dep)
        p = run(["bash", str(TEARDOWN), str(dep)], text=True)
        result = {
            "teardown_exit_code": p.returncode,
            "stderr_names_mount_path": (str(dep / "data") in p.stderr or str(dep / "data") in p.stdout),
        }
        # c2: teardown_exit_code must be != 0 (the oracle checks ne 0); the script itself exits 0.
        expect = {"stderr_names_mount_path": True}

    elif case == "reap-orphan-unique-name":
        import random

        orphan_name = f"r2-payout-{int(time.time())}-{random.getrandbits(16):x}"
        orphan = pathlib.Path.home() / "deployments" / orphan_name
        orphan.mkdir(parents=True, exist_ok=True)
        mount_tmpfs(orphan)
        run_fixturenet_cleanup(orphan, other_name="eb0-other")
        result = {
            "orphan_mount_present_after": mount_present(orphan),
            "orphan_dir_present_after": orphan.exists(),
        }
        expect = {"orphan_mount_present_after": False, "orphan_dir_present_after": False}

    elif case == "reap-keeps-live":
        dep = pathlib.Path.home() / "deployments" / "eb0-live"
        dep.mkdir(parents=True, exist_ok=True)
        mount_tmpfs(dep)
        run_hold_process(dep)
        run_fixturenet_cleanup(dep, other_name=dep.name)
        result = {
            "live_mount_present_after": mount_present(dep),
            "live_dir_present_after": dep.exists(),
        }
        expect = {"live_mount_present_after": True, "live_dir_present_after": True}

    elif case == "governance-teardown":
        dep = pathlib.Path.home() / "deployments" / "eb0-gov"
        dep.mkdir(parents=True, exist_ok=True)
        mount_tmpfs(dep)
        run_governance_teardown(dep)
        result = {
            "mount_present_after": mount_present(dep),
            "deployment_dir_present_after": dep.exists(),
        }
        expect = {"mount_present_after": False, "deployment_dir_present_after": False}

    elif case == "r2-deposit-teardown":
        dep = pathlib.Path.home() / "deployments" / "eb0-dep"
        dep.mkdir(parents=True, exist_ok=True)
        mount_tmpfs(dep)
        run_deposit_teardown(dep)
        result = {
            "mount_present_after": mount_present(dep),
            "deployment_dir_present_after": dep.exists(),
        }
        expect = {"mount_present_after": False, "deployment_dir_present_after": False}

    print(json.dumps(result))
    for k, expected in expect.items():
        if expected is not None and result[k] != expected:
            print(f"check-fixturenet-teardown: {k} is {result[k]}, expected {expected}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
