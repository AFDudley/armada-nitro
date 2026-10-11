#!/usr/bin/env python3
"""armada-custodian-e2e gate checker (E14c steps 1-2).

Builds frost-signer for the container's glibc (a static musl binary -- the host's glibc is
newer than the env image's Debian bookworm, so a glibc-linked build would not run there),
then runs the `armada-custodian-e2e` job through the shared job helper
(scripts/armada_job_helper.py, arn-895), which builds the job's image from this checkout's
committed content if it is missing, selects it (ARMADA_IMAGE_TAG via `laconic-so deploy
create --update`), and calls run-job, then parses the job's structured JSON output and
re-emits the six required fields:

  authorize_delegate_success, authorize_delegate_tx_hash, close_success, close_tx_hash,
  is_active_delegate, payout_matches_allocations.

Exits 0 when both steps pass; exits non-zero otherwise.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

_scripts_dir = os.path.dirname(os.path.abspath(__file__))  # <repo>/scripts
_repo_root = os.path.dirname(_scripts_dir)  # <repo>
sys.path.insert(0, _scripts_dir)
from armada_job_helper import run_job as _helper_run_job  # noqa: E402

JOB = "armada-custodian-e2e"
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
    """Run the gate job through the shared helper (which builds/selects the job's
    HEAD-sha image first) and capture its stdout (the final JSON line)."""
    # The job's compose file mounts this host binary into the container.
    job_stdout, returncode = _helper_run_job(
        JOB, extra_env={"FROST_SIGNER_BIN": FROST_SIGNER_BIN}, timeout=900
    )
    if not job_stdout and returncode != 0:
        print("TIMEOUT: job did not finish within 900s", file=sys.stderr)
        return 1

    job_stderr = ""

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
        print(f"run-job failed (exit={returncode}).", file=sys.stderr)
        print(job_stdout, file=sys.stderr)
        if job_stderr:
            print(job_stderr, file=sys.stderr)
        return 1

    # Re-emit the E14c fields plus the E14d fields (step3, step4, discrimination a-d) and
    # compute `all_passed` as the logical AND of the seven named E14d checks.
    out = {
        "authorize_delegate_success": job_json.get("authorize_delegate_success"),
        "authorize_delegate_tx_hash": job_json.get("authorize_delegate_tx_hash", ""),
        "close_success": job_json.get("close_success"),
        "close_tx_hash": job_json.get("close_tx_hash", ""),
        "is_active_delegate": job_json.get("is_active_delegate"),
        "payout_matches_allocations": job_json.get("payout_matches_allocations"),
        # E14d fields
        "step3_delegate_still_active_before_delay": job_json.get("step3_delegate_still_active_before_delay"),
        "step3_revoked_delegate_rejected_after_delay": job_json.get(
            "step3_revoked_delegate_rejected_after_delay"
        ),
        "step3_revoked_delegate_rejected_after_delay_evidence": job_json.get(
            "step3_revoked_delegate_rejected_after_delay_evidence", ""
        ),
        "step4_old_group_signature_rejected": job_json.get("step4_old_group_signature_rejected"),
        "step4_old_group_signature_rejected_evidence": job_json.get(
            "step4_old_group_signature_rejected_evidence", ""
        ),
        "discrimination_a_single_signer_rejected": job_json.get("discrimination_a_single_signer_rejected"),
        "discrimination_a_single_signer_rejected_evidence": job_json.get(
            "discrimination_a_single_signer_rejected_evidence", ""
        ),
        "discrimination_b_replay_rejected": job_json.get("discrimination_b_replay_rejected"),
        "discrimination_b_replay_rejected_evidence": job_json.get(
            "discrimination_b_replay_rejected_evidence", ""
        ),
        "discrimination_c_revoked_delegate_rejected": job_json.get(
            "discrimination_c_revoked_delegate_rejected"
        ),
        "discrimination_c_revoked_delegate_rejected_evidence": job_json.get(
            "discrimination_c_revoked_delegate_rejected_evidence", ""
        ),
        "discrimination_d_wrong_hash_rejected": job_json.get("discrimination_d_wrong_hash_rejected"),
        "discrimination_d_wrong_hash_rejected_evidence": job_json.get(
            "discrimination_d_wrong_hash_rejected_evidence", ""
        ),
        "all_passed": None,
        "exit_code": returncode,
    }
    # c8: all_passed is the logical AND of the seven named E14d checks.
    all_passed = (
        out["step3_delegate_still_active_before_delay"] is True
        and out["step3_revoked_delegate_rejected_after_delay"] is True
        and out["step4_old_group_signature_rejected"] is True
        and out["discrimination_a_single_signer_rejected"] is True
        and out["discrimination_b_replay_rejected"] is True
        and out["discrimination_c_revoked_delegate_rejected"] is True
        and out["discrimination_d_wrong_hash_rejected"] is True
    )
    out["all_passed"] = all_passed
    print(json.dumps(out))
    # The checker exits 0 only when the job succeeded AND all seven E14d checks are true.
    return 0 if (returncode == 0 and out["all_passed"]) else 1


def main() -> int:
    build_frost_signer()
    return run_job()


if __name__ == "__main__":
    sys.exit(main())
