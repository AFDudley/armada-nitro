#!/usr/bin/env python3
"""arn-3d8 acceptance checker (metamorphic pair).

For each deposit entry point, the checker runs the single metamorphic test that proves the
configured-status relation: a listed-token deposit credits the channel, an unlisted-token deposit
reverts with 'Asset not configured'. The reducer re-runs this exact script as the merge gate.

    python3 scripts/check-adjudicator-asset-list.py --entrypoint deposit
    python3 scripts/check-adjudicator-asset-list.py --entrypoint depositFromNote

Exits 0 only when the relation holds for the requested entry point.
"""

from __future__ import annotations

import argparse
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
    parser.add_argument(
        "--entrypoint", choices=sorted(_TESTS), required=True, help="which deposit entry point to verify"
    )
    args = parser.parse_args()

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    test_name = _TESTS[args.entrypoint]

    # --match-contract pins the test contract; --match-test selects the single metamorphic test.
    cmd = [
        "forge",
        "test",
        "--match-contract",
        _TEST_CONTRACT,
        "--match-test",
        test_name,
        "-vv",
    ]
    result = subprocess.run(cmd, cwd=repo_root)

    if result.returncode != 0:
        print(f"FAIL: metamorphic relation not held for entrypoint '{args.entrypoint}'", file=sys.stderr)
    sys.exit(0 if result.returncode == 0 else 1)


if __name__ == "__main__":
    main()
