#!/usr/bin/env python3
"""Run the adopt deploy-standin test suite and output JSON results.

Usage:  python3 scripts/run_adopt_standin_suite.py

Outputs JSON on stdout with keys:
    tests_run  — number of module checks executed
    all_passed — boolean, true when no module's adopt path reaches deploy

Called by the acceptance gate:
    scripts/run_adopt_standin_suite.py  →  {"tests_run": 7, "all_passed": true}
"""

from __future__ import annotations

import json
import sys

from tests.reconciler.test_adopt_deploy_standin import _run_all_tests


def main() -> int:
    results = _run_all_tests()
    all_passed = all(results.values())
    output = {
        "tests_run": len(results),
        "all_passed": all_passed,
    }
    print(json.dumps(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
