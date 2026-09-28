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
from pathlib import Path

# Locate the repo so `tests.reconciler...` (repo root) and `reconciler...` (env/)
# both import when run as `python3 scripts/run_adopt_standin_suite.py` from the
# repo root with no PYTHONPATH set.
_REPO_ROOT = Path(__file__).resolve().parents[1]
for _p in (str(_REPO_ROOT), str(_REPO_ROOT / "env")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from tests.reconciler.test_adopt_deploy_standin import _run_all_tests  # noqa: E402


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
