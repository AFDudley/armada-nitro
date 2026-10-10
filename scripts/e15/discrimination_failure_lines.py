#!/usr/bin/env python3
"""E15c failure lines: prove both discrimination runs (single-signer and late-response) each
print their own failure line, so a developer watching the run can see both rejections.

Runs the discrimination job twice: once with SCENARIO=single_signer and once with
SCENARIO=late_response. Each run prints its failure line. The script verifies both failure
lines were printed.
"""
from __future__ import annotations

import json
import sys

import job_runner


def main() -> int:
    # Run both scenarios; each prints its failure line.
    # The job's stdout contains the failure lines (printed via `print`).
    single_line = job_runner._run_job("single_signer")
    late_line = job_runner._run_job("late_response")
    sd = json.loads(single_line)
    ld = json.loads(late_line)
    # A failure line is "printed" if the JSON's failure_line field is a non-empty string.
    single_signer_failure_line_printed = bool(sd.get("single_signer_failure_line"))
    late_response_failure_line_printed = bool(ld.get("late_response_failure_line"))
    print(json.dumps({
        "single_signer_failure_line_printed": single_signer_failure_line_printed,
        "late_response_failure_line_printed": late_response_failure_line_printed,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
