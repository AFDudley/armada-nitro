#!/usr/bin/env python3
"""arn-40f checker: MultiAssetHolder._transferAsset pays out an ERC20 asset through the
adjudicator, or the call reverts — value is conserved.

Runs the PayoutConservation tests (test/PayoutConservation.t.sol):
  - test_returnsFalse: a token whose transfer returns false MUST revert the whole payout,
    leaving channel holdings and the destination balance unchanged (c1).
  - test_returnsTrue: a standard token that returns true pays the full amount to the
    destination; channel holdings drop by exactly that amount (c2).
  - test_returnsNothing: a USDT-like token that returns no value pays the full amount to the
    destination; value is conserved (c2).

The outer loop drives this script with `--token <kind>`:
  - c1: `python3 scripts/check-adjudicator-payout-conservation.py --token returns-false`
  - c2: `python3 scripts/check-adjudicator-payout-conservation.py --token returns-true --token returns-nothing`

Prints one JSON line mapping each requested token kind to its test result.
Exits 0 when every requested token kind passes; non-zero otherwise.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

_TEST_FILE = "test/PayoutConservation.t.sol"
CONTRACT = "PayoutConservationTest"

# Map each token kind to the test that proves its conservation property.
KIND_TO_TEST = {
    "returns-false": "test_returnsFalse",
    "returns-true": "test_returnsTrue",
    "returns-nothing": "test_returnsNothing",
}


def forge_bin() -> str:
    """Resolve the forge binary: prefer one on PATH, else fall back to the foundry install."""
    import glob
    import shutil

    forge = shutil.which("forge")
    if forge:
        return forge
    candidates = [
        os.path.join(os.path.expanduser("~"), ".foundry", "bin", "forge"),
    ]
    candidates += sorted(
        glob.glob(os.path.join(os.path.expanduser("~"), ".foundry", "versions", "*", "*", "forge"))
    )
    for path in candidates:
        if os.path.exists(path):
            return path
    raise FileNotFoundError("forge binary not found; install foundry or add it to PATH")


def run_forge() -> str:
    """Run the PayoutConservation tests, forwarding forge output to stderr."""
    proc = subprocess.run(
        [forge_bin(), "test", _TEST_FILE, "--match-contract", CONTRACT],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if proc.stderr:
        sys.stderr.write("=== forge stderr ===\n" + proc.stderr + "\n")
    return proc.stdout + proc.stderr


def parse_results(output: str) -> dict[str, bool]:
    """Parse forge's [PASS]/[FAIL] lines into a {test_name: passed} map."""
    results: dict[str, bool] = {}
    for match in re.finditer(
        r"\[(PASS|FAIL)[^]]*\]\s+([A-Za-z0-9_]+)\s*\(",
        output,
    ):
        result, name = match.group(1), match.group(2)
        if name in KIND_TO_TEST.values():
            results[name] = result == "PASS"
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--token",
        action="append",
        dest="tokens",
        default=[],
        help="token kind to check (repeatable): returns-false, returns-true, returns-nothing",
    )
    args = parser.parse_args()

    if not args.tokens:
        parser.error("at least one --token kind is required")

    for kind in args.tokens:
        if kind not in KIND_TO_TEST:
            sys.stderr.write(f"unknown token kind: {kind!r}\n")
            print(json.dumps({}), file=sys.stderr)
            return 65  # JFIF: usage error (EXARG)
        if args.tokens:
            # dedupe while preserving order
            pass

    seen = set()
    requested = []
    for kind in args.tokens:
        if kind in KIND_TO_TEST and kind not in seen:
            seen.add(kind)
            requested.append(kind)

    # Guard: reject unknown kinds so a typo does not silently pass.
    for kind in args.tokens:
        if kind not in KIND_TO_TEST:
            sys.stderr.write(f"unknown token kind: {kind!r}\n")
            print(json.dumps({}), file=sys.stderr)
            return 65

    # If no kinds requested, exit 0 (gate may call with no --token).
    if not requested:
        print(json.dumps({}))
        return 0

    output = run_forge()
    results = parse_results(output)

    # Build the report: for each requested token kind, record whether its test passed.
    report = {}
    for kind in requested:
        test_name = KIND_TO_TEST[kind]
        # If the test never ran (forge crashed), treat as failed.
        report[kind] = results.get(test_name, False)
    print(json.dumps(report))

    return 0 if all(report.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
