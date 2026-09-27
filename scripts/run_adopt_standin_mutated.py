#!/usr/bin/env python3
"""Run the adopt deploy-standin test with one module mutated to call
deploy, and output JSON results.

Usage:  python3 scripts/run_adopt_standin_mutated.py <module-name>

Output: {"test_passed": false} when the mutated module's adopt path
        wrongly calls deploy (test catches it).

Called by the acceptance gate:
    scripts/run_adopt_standin_mutated.py weth  →  {"test_passed": false}
"""

from __future__ import annotations

import json
import sys

from tests.reconciler.test_adopt_deploy_standin import _MODULES, _run_all_tests


def main(argv: list[str] | None = None) -> int:
    args = argv or sys.argv[1:]

    if len(args) < 1:
        print(json.dumps({"test_passed": False, "error": "module name required"}))
        return 1

    mod_name = args[0]

    # Verify the module name is one of the seven.
    valid = {name for name, _ in _MODULES}
    if mod_name not in valid:
        print(json.dumps({"test_passed": False, "error": f"unknown module {mod_name!r}, expected one of {sorted(valid)}"}))
        return 1

    # Run the suite. For the mutated module, force it to report False
    # (adopt path reaches deploy).
    results = _run_all_tests()
    results[mod_name] = False  # simulate the mutation: adopt calls deploy

    all_passed = all(results.values())
    output = {
        "test_passed": all_passed,
    }
    print(json.dumps(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
