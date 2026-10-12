#!/usr/bin/env python3
"""arn-0cf checker: MultiAssetHolder.deposit credits the measured token balance, not the
requested amount.

Runs the two DepositAmount tests (test/DepositAmount.t.sol):
  - test_shortTransfer_depositReverts: a token that pays one unit less than requested
    MUST revert the deposit (c1).
  - test_normalDeposit_holdingsDeltaEqualsBalanceDelta: a normal token that pays the full
    requested amount leaves the recorded holdings increase equal to the adjudicator's
    measured token balance increase (c2).

Prints one JSON line:
  {"short_transfer_deposit_reverted": true, "normal_deposit_holdings_delta_equals_balance_delta": true}
Exits 0 when both tests pass; non-zero otherwise.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_TEST_FILE = "test/DepositAmount.t.sol"
_SHORT_TEST = "test_shortTransfer_depositReverts"
_NORMAL_TEST = "test_normalDeposit_holdingsDeltaEqualsBalanceDelta"

# Map the two test function names to their JSON fields.
_TESTS = {
    _SHORT_TEST: "short_transfer_deposit_reverted",
    _NORMAL_TEST: "normal_deposit_holdings_delta_equals_balance_delta",
}


def _run_forge() -> str:
    proc = subprocess.run(
        ["forge", "test", _TEST_FILE],
        cwd=_REPO_ROOT,
        capture_output=True,
        text=True,
    )
    return proc.stdout + proc.stderr


def _parse_test_results(output: str) -> dict[str, bool]:
    """Parse forge's per-test [PASS]/[FAIL] lines into a boolean map."""
    passed: dict[str, bool] = {name: False for name in _TESTS}
    # Forge prints: "[PASS] test_name() (gas: N)" or "[FAIL: reason] test_name() (gas: N)".
    for match in re.finditer(r"\[(PASS|FAIL)[^]]*\]\s+([A-Za-z0-9_]+)\s*\(", output):
        result, name = match.group(1), match.group(2)
        if name in _TESTS:
            passed[name] = result == "PASS"
    # Key the report by the JSON field names so main() can read the right keys.
    report = {field: passed[name] for name, field in _TESTS.items()}
    return report


def main() -> int:
    output = _run_forge()
    report = _parse_test_results(output)
    print(json.dumps(report))
    return 0 if all(report.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
