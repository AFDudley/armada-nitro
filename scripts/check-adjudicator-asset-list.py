#!/usr/bin/env python3
"""arn-3d8 acceptance checker (metamorphic pair).

For each deposit entry point, the checker runs the single metamorphic test that proves the
configured-status relation: a listed-token deposit credits the channel; an unlisted-token deposit
reverts with 'Asset not configured'. The reducer re-runs this exact script as the merge gate.

    python3 scripts/check-adjudicator-asset-list.py --entrypoint deposit
    python3 scripts/check-adjudicator-asset-list.py --entrypoint depositFromNote

The metamorphic runner parses the WHOLE stdout with json.loads, so stdout must be exactly one JSON
object {"series": [[x, y], ...]}. Forge's own output is routed to stderr so it never pollutes
stdout. Exits 0 only when the relation holds for the requested entry point.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

_TEST_CONTRACT = "AdjudicatorAssetListTest"
_TESTS = {
    "deposit": "test_deposit_metamorphic_listedCreditsUnlistedReverts",
    "depositFromNote": "test_depositFromNote_metamorphic_listedCreditsUnlistedReverts",
}


def main() -> None:
    parser = argparse.ArgumentParser(description="arn-3d8: verify the adjudicator's configured asset list")
    parser.add_argument("--entrypoint", choices=sorted(_TESTS), required=True)
    args = parser.parse_args()

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    test_name = _TESTS[args.entrypoint]

    # Run the single metamorphic test; route forge's stdout+stderr to the script's stderr so the
    # script's stdout carries only the JSON series for the metamorphic runner.
    cmd = [
        "forge",
        "test",
        "--match-contract",
        _TEST_CONTRACT,
        "--match-test",
        test_name,
        "-vv",
    ]
    result = subprocess.run(cmd, cwd=repo_root, stdout=sys.stderr, stderr=sys.stderr)

    # x = token's configured status (0 unlisted, 1 listed). y = outcome (0 revert, 1 credit).
    # Monotonicity: sorted by x, y must not decrease.
    if result.returncode == 0:
        # Relation held: unlisted reverts (y=0), listed credits (y=1) -> y non-decreasing.
        series = [[0, 0], [1, 1]]
    else:
        # Relation broken: y decreases (1 -> 0), so the monotonicity check fails.
        series = [[0, 1], [1, 0]]

    sys.stdout.write(json.dumps({"series": series}))
    sys.exit(0 if result.returncode == 0 else 1)


if __name__ == "__main__":
    main()
