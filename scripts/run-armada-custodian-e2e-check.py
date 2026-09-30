#!/usr/bin/env python3
"""armada-custodian-e2e gate checker (E14c steps 1-2).

Builds frost-signer for the container's glibc (a static musl binary -- the host's glibc is
newer than the `cerc/armada-nitro-env:local` image's Debian bookworm, so a glibc-linked
build would not run there), then runs the `armada-custodian-e2e` job via `laconic-so
deployment --dir <dep> run-job armada-custodian-e2e` (laconic-so is a Python shiv that only
loads under the system python3.12, not the venv's python3.14), then parses the job's
structured JSON output and re-emits the six required fields:

  authorize_delegate_success, authorize_delegate_tx_hash, close_success, close_tx_hash,
  is_active_delegate, payout_matches_allocations.

Exits 0 when both steps pass; exits non-zero otherwise.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

# The deployment the job runs against (operator-managed fixturenet deployed per E14b).
DEP_DIR = os.path.expanduser("~/deployments/armada-fixturenet-e12")
# /home/rix/bin/laconic-so is the self-contained shiv (a bundled zipapp needing only a bare
# python3.12, no installed packages) -- a literal absolute path, not `~`-expanded, because
# exophial's oracle re-run sandboxes $HOME for the re-run subprocess, which would otherwise
# resolve `~` to a scratch directory with no laconic-so at all. PATH (shutil.which) is not a
# safe fallback: on this host it resolves first to ~/.local/bin/laconic-so, a thin pipx
# console-script wrapper that imports `stack_orchestrator` from its own dedicated venv --
# forcing it through a bare python3.12 (below) raises ModuleNotFoundError.
_LITERAL_SHIV = "/home/rix/bin/laconic-so"
LA_CONIC_SO = _LITERAL_SHIV if os.path.isfile(_LITERAL_SHIV) else os.path.expanduser("~/bin/laconic-so")
PYTHON_312 = "/usr/bin/python3.12"

_scripts_dir = os.path.dirname(os.path.abspath(__file__))  # <repo>/scripts
_repo_root = os.path.dirname(_scripts_dir)  # <repo>
# The container has no cargo/rustc; the checker builds a static musl binary on the host and
# the job's compose file volume-mounts it in (FROST_SIGNER_BIN is a host path).
FROST_SIGNER_BIN = os.path.join(_repo_root, "target/x86_64-unknown-linux-musl/release/frost-signer")


def build_frost_signer() -> None:
    result = subprocess.run(
        [
            "cargo",
            "build",
            "--release",
            "--target",
            "x86_64-unknown-linux-musl",
            "--manifest-path",
            os.path.join(_repo_root, "tools/frost-signer/Cargo.toml"),
        ],
        cwd=_repo_root,
        capture_output=True,
        text=True,
        timeout=300,
    )
    if result.returncode != 0:
        print("cargo build --release --target x86_64-unknown-linux-musl failed:", file=sys.stderr)
        print(result.stdout, file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        raise SystemExit(1)
    if not os.path.isfile(FROST_SIGNER_BIN):
        print(f"expected frost-signer binary at {FROST_SIGNER_BIN}, not found", file=sys.stderr)
        raise SystemExit(1)


def run_job() -> int:
    """Run the gate job and capture its stdout (the final JSON line)."""
    cmd = [
        PYTHON_312,
        LA_CONIC_SO,
        "deployment",
        "--dir",
        DEP_DIR,
        "run-job",
        "armada-custodian-e2e",
    ]
    env = os.environ.copy()
    # The job's compose file mounts this host binary into the container.
    env["FROST_SIGNER_BIN"] = FROST_SIGNER_BIN
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=900,
            env=env,
        )
    except subprocess.TimeoutExpired:
        print("TIMEOUT: job did not finish within 900s", file=sys.stderr)
        return 1

    job_stdout = result.stdout or ""
    job_stderr = result.stderr or ""

    # The job emits a final JSON line like:
    # {"authorize_delegate_success": true, "authorize_delegate_tx_hash": "0x...",
    #  "close_success": true, "close_tx_hash": "0x...", "is_active_delegate": true,
    #  "payout_matches_allocations": true}
    # Extract it (the last JSON-looking line in the job's stdout).
    job_json = None
    for line in reversed(job_stdout.splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                job_json = json.loads(line)
                break
            except json.JSONDecodeError:
                continue
    if job_json is None:
        print(f"run-job failed (exit={result.returncode}).", file=sys.stderr)
        print(job_stdout, file=sys.stderr)
        if job_stderr:
            print(job_stderr, file=sys.stderr)
        return 1

    # Re-emit the six required fields (and the exit code for c5).
    out = {
        "authorize_delegate_success": job_json.get("authorize_delegate_success"),
        "authorize_delegate_tx_hash": job_json.get("authorize_delegate_tx_hash", ""),
        "close_success": job_json.get("close_success"),
        "close_tx_hash": job_json.get("close_tx_hash", ""),
        "is_active_delegate": job_json.get("is_active_delegate"),
        "payout_matches_allocations": job_json.get("payout_matches_allocations"),
        "exit_code": result.returncode,
    }
    print(json.dumps(out))
    both_pass = (
        result.returncode == 0
        and out["authorize_delegate_success"] is True
        and out["close_success"] is True
        and out["payout_matches_allocations"] is True
        and out["is_active_delegate"] is True
        and out["authorize_delegate_tx_hash"] != ""
        and out["close_tx_hash"] != ""
    )
    return 0 if both_pass else 1


def main() -> int:
    build_frost_signer()
    return run_job()


if __name__ == "__main__":
    sys.exit(main())
