#!/usr/bin/env python3
"""Gate script for the arn-5db acceptance spec (derived-arn-5db), clause c2.

The exophial metamorphic gate runs exactly:
    python3 scripts/check-settlement-rate-free-gate.py
and (for relation_class=monotonicity) parses the entire stdout as a single
JSON object of shape:
    {"series": [[x1, y1], [x2, y2]]
where each entry is [x, y] and passes when y is non-decreasing as x increases.
A non-zero exit, or stdout that is not one JSON value, fails the check.

Clause c2 says the forge suite is itself the enforcement: running `forge test`
executes the S6 rule check and fails when a forbidden name is present in the
adjudicator source. So this script does not re-implement the scan in Python;
its pass/fail verdict is computed from the real execution of the enforcing
Solidity test:
    forge test test/SettlementRateFree.t.sol

Behaviour:
  * Runs `forge test test/SettlementRateFree.t.sol --json` (subprocess) and
    reads the SettlementRateFreeTest suite's real test results.
  * When the enforcing test file is present and every result is Success, it
    emits exactly one JSON object {"series": [[0, 0], [1, 1]] and exits 0,
    so the gate (monotonicity) PASSES.
  * When the test file is deleted, forge reports "no tests match" (still exit
    0, no suite in the JSON) -> this script exits non-zero, so the gate
    FAILS instead of silently passing.

Run it with --scan-file PATH to scan a single scratch copy of the adjudicator source
(kept for the c1 grep_absent clause); with no args it drives `forge test` as above.
"""

import json
import os
import subprocess
import sys

# c1 forbidden names (the set the grep_absent clause enforces).
FORBIDDEN = [
    "ERC4626",
    "IERC4626",
    "convertToAssets",
    "convertToShares",
    "preview",
]

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADJUDICATOR = os.path.join(REPO_ROOT, "src", "ArmadaNitroAdjudicator.sol")
NITRO_ROOT = os.path.join(REPO_ROOT, "src", "nitro")
FORGE_TEST_FILE = "test/SettlementRateFree.t.sol"
SUITE_ID = "test/SettlementRateFree.t.sol:SettlementRateFreeTest"


def collect_files() -> list[str]:
    """The adjudicator contract + every .sol under src/nitro."""
    files = [ADJUDICATOR]
    if os.path.isdir(NITRO_ROOT):
        for dirpath, _dirs, filenames in os.walk(NITRO_ROOT):
            for fn in filenames:
                if fn.endswith(".sol"):
                    files.append(os.path.join(dirpath, fn))
    return files


def scan_files(paths: list[str]) -> list[tuple[str, int, str]]:
    """Scan .sol files; return hits as (file, line_no, name) tuples."""
    hits = []
    for path in paths:
        try:
            with open(path, encoding="utf-8") as f:
                for line_no, line in enumerate(f, 1):
                    for name in FORBIDDEN:
                        if name in line:
                            hits.append((path, line_no, name))
        except FileNotFoundError:
            pass
    return hits


def run_forge(json_output: bool = True) -> tuple[int, str, str]:
    """Run the enforcing forge test; return (returncode, stdout, stderr)."""
    cmd = ["forge", "test", FORGE_TEST_FILE]
    if json_output:
        cmd.append("--json")
    res = subprocess.run(cmd, cwd=REPO_ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return res.returncode, res.stdout, res.stderr


def check_forge() -> int:
    """Compute the c2 verdict from forge test's real execution of SettlementRateFreeTest."""
    rc, stdout, stderr = run_forge(json_output=True)
    # Forge itself crashed or failed to compile.
    if rc != 0:
        print(f"forge test exited {rc}:\n{stderr}", file=sys.stderr)
        return 1
    try:
        data = json.loads(stdout)
    except (json.JSONDecodeError, ValueError):
        # Deleted file -> forge printed 'no tests match' and no JSON object; the
        # enforcing test did not run, so the suite is not being exercised.
        print(f"forge test ran no tests (no tests match): {FORGE_TEST_FILE}\n{stderr}", file=sys.stderr)
        return 1
    # Find the SettlementRateFreeTest suite by id.
    suite = None
    for k, v in data.items():
        if k == SUITE_ID or k.endswith("SettlementRateFreeTest"):
            suite = v
            break
    if suite is None:
        print("SettlementRateFreeTest suite not found in forge output", file=sys.stderr)
        return 1
    results = suite.get("test_results", {})
    # Pass only when the enforcing tests actually ran and all passed.
    if not results:
        print("no test_results for SettlementRateFreeTest", file=sys.stderr)
        return 1
    for name, r in results.items():
        if r.get("status") != "Success":
            print(f"test {name} status={r.get('status')}: {r.get('reason')}", file=sys.stderr)
            return 1
    # Clean: emit exactly one JSON object for the monotonicity oracle.
    json.dump({"series": [[0, 0], [1, 1]]}, sys.stdout)
    print()
    return 0


def scan_and_report(files: list[str]) -> int:
    """c1 grep_absent gate: scan for forbidden names, report hits, fail the suite."""
    hits = scan_files(files)
    if hits:
        for path, line_no, name in hits:
            print(f"{os.path.relpath(path, REPO_ROOT)}:{line_no}: {name}", file=sys.stderr)
        return 1
    json.dump({"series": [[0, 0], [1, 1]]}, sys.stdout)
    print()
    return 0


def main(argv: list[str]) -> int:
    scan_file = None
    i = 0
    while i < len(argv):
        if argv[i] == "--scan-file":
            scan_file = argv[i + 1]
            i += 2
            continue
        i += 1

    # c2 verdict is driven by forge test's real execution.
    if scan_file is not None:
        files = [os.path.join(REPO_ROOT, scan_file)]
        return scan_and_report(files)

    return check_forge()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
