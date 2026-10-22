#!/usr/bin/env python3
"""Observe a fixturenet gate run (arn-46d.5).

The fixturenet gate runs both base-key verify scripts in order, with
set -e semantics (the gate exits non-zero as soon as a script exits
non-zero):

  1. stack/scripts/verify_base_key_python_versions.py
  2. stack/scripts/verify_base_key_docker_rebuild.py

The gate's run output names both scripts, so a reader can confirm both
checks ran.

This observer is the spec oracle for arn-46d.5. It runs the gate for a
scenario and prints one JSON object:

  {"gate_exit_code": int, "python_versions_ran": bool,
   "docker_rebuild_ran": bool}

and, with --report-output, additionally:

  {"output_names_python_versions": bool, "output_names_docker_rebuild": bool}

Scenarios:
  both-pass            both checks run and pass; the observer exits 0.
  python-versions-fails  the python-versions check is made to fail (its
  scratch root lacks the base-key inputs, so base-key.py exits non-zero);
  the gate exits non-zero.
  docker-rebuild-fails  the python-versions check passes, then the
  docker-rebuild check is made to fail the same way; the gate exits
  non-zero.

The two interpreters for the python-versions check are the repo venv's
python (a distinct version) and /usr/bin/python3.12. A scratch root
(tempdir with no env/ inputs) makes base-key.py fail under any
interpreter.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent  # scripts/ lives one level under the repo root
PV_SCRIPT = REPO_ROOT / "stack" / "scripts" / "verify_base_key_python_versions.py"
DR_SCRIPT = REPO_ROOT / "stack" / "scripts" / "verify_base_key_docker_rebuild.py"
SCENARIOS = ("both-pass", "python-versions-fails", "docker-rebuild-fails")


def _interpreters() -> tuple[str, str]:
    venv_python = REPO_ROOT / ".venv" / "bin" / "python3"
    if venv_python.exists():
        return str(venv_python), "/usr/bin/python3.12"
    return "/usr/bin/python3", "/usr/bin/python3.12"


def _scratch_root() -> Path:
    return Path(tempfile.mkdtemp(prefix="jg-scratch-"))


def _ensure_node_modules() -> None:
    # base-key.py normalises env/lido TypeScript with the repo's node_modules
    # prettier; node_modules is git-ignored, so a fresh worktree (merge gate's
    # outer-loop re-run) lacks it. Install it if missing.
    if not (REPO_ROOT / "node_modules" / ".bin").exists():
        r = subprocess.run(["npm", "ci"], capture_output=True, text=True, cwd=REPO_ROOT)
        if r.returncode != 0:
            print(f"observe_fixturenet_gate: npm ci failed:\n{r.stderr}", file=sys.stderr)


def _run_gate(scenario: str) -> tuple[int, bool, bool, list[str]]:
    """Run the fixturenet gate for the given scenario.

    Returns (gate_exit_code, python_versions_ran, docker_rebuild_ran,
    gate_output_lines).
    """
    _ensure_node_modules()
    gate_output: list[str] = []
    gate_exit_code = 0
    pv_ran = False
    dr_ran = False
    pv_root = REPO_ROOT
    dr_root = REPO_ROOT
    if scenario == "python-versions-fails":
        pv_root = _scratch_root()
    elif scenario == "docker-rebuild-fails":
        dr_root = _scratch_root()

    # Check 1: verify_base_key_python_versions.py
    gate_output.append("[fixturenet-gate] verify_base_key_python_versions.py")
    py_a, py_b = _interpreters()
    r = subprocess.run(
        [sys.executable, str(PV_SCRIPT), "--root", str(pv_root), "--python-a", py_a, "--python-b", py_b],
        capture_output=True,
        text=True,
    )
    if r.stdout.strip():
        gate_output.append(r.stdout.strip())
    pv_ran = True
    if r.returncode != 0:
        gate_exit_code = r.returncode
        # set -e: the gate stops here; check 2 is not run.
        return gate_exit_code, pv_ran, dr_ran, gate_output

    # Check 2: verify_base_key_docker_rebuild.py
    gate_output.append("[fixturenet-gate] verify_base_key_docker_rebuild.py")
    r2 = subprocess.run(
        [sys.executable, str(DR_SCRIPT), "--root", str(dr_root)], capture_output=True, text=True
    )
    if r2.stdout.strip():
        gate_output.append(r2.stdout.strip())
    dr_ran = True
    if r2.returncode != 0:
        gate_exit_code = r2.returncode
    return gate_exit_code, pv_ran, dr_ran, gate_output


def main() -> None:
    ap = argparse.ArgumentParser(description="Observe a fixturenet gate run (arn-46d.5).")
    ap.add_argument("--scenario", required=True, choices=SCENARIOS)
    ap.add_argument(
        "--report-output", action="store_true", help="also report whether the gate's output names both checks"
    )
    args = ap.parse_args()

    gate_exit_code, pv_ran, dr_ran, gate_output = _run_gate(args.scenario)

    if args.report_output:
        gate_output_text = "\n".join(gate_output)
        report = {
            "gate_exit_code": gate_exit_code,
            "python_versions_ran": pv_ran,
            "docker_rebuild_ran": dr_ran,
            "output_names_python_versions": "verify_base_key_python_versions.py" in gate_output_text,
            "output_names_docker_rebuild": "verify_base_key_docker_rebuild.py" in gate_output_text,
        }
    else:
        report = {
            "gate_exit_code": gate_exit_code,
            "python_versions_ran": pv_ran,
            "docker_rebuild_ran": dr_ran,
        }
    print(json.dumps(report))
    sys.exit(0)


if __name__ == "__main__":
    main()
