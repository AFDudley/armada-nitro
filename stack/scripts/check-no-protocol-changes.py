#!/usr/bin/env python3
"""arn-2fd c6: the selective-disclosure acceptance work changes no pool contract, no disclosure
circuit and no adjudicator contract.

The adjudicator contract lives in this repo at src/ArmadaNitroAdjudicator.sol. The pool contract
lives in the lib/armada-poc submodule; this repo records only its gitlink (a pinned commit), so a
pool-contract change here would show up as lib/armada-poc's gitlink entry changing. The
disclosure circuit (armada-circuits' NullifierDisclosure.circom) lives in a separate repository
entirely and is not vendored into this one -- there is no path in this repo that could represent
it changing.

Diffs against the local `main` branch if present, else `origin/main`, else the pebble's recorded
base commit (26b918fa46f62ddd7ff811f8d76c5964bc0a3cc7) -- the branch this work forked from.

Prints one JSON line: {"changed_protocol_files": <int>}. Zero when none of the above differ.
"""

from __future__ import annotations

import json
import subprocess
import sys

FALLBACK_BASE = "26b918fa46f62ddd7ff811f8d76c5964bc0a3cc7"
PROTOCOL_PATHS = ["src/ArmadaNitroAdjudicator.sol", "lib/armada-poc"]


def _rev_exists(rev: str) -> bool:
    return (
        subprocess.run(["git", "rev-parse", "--verify", "--quiet", rev], capture_output=True).returncode == 0
    )


def _base_ref() -> str:
    for candidate in ("main", "origin/main"):
        if _rev_exists(candidate):
            return candidate
    return FALLBACK_BASE


def main() -> int:
    base = _base_ref()
    r = subprocess.run(
        ["git", "diff", "--name-only", f"{base}...HEAD", "--", *PROTOCOL_PATHS],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
        return 1
    changed = [line for line in r.stdout.splitlines() if line.strip()]
    print(json.dumps({"changed_protocol_files": len(changed)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
