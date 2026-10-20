#!/usr/bin/env python3
"""c6: After the change, no pool contract, disclosure circuit or adjudicator contract file differs
from the main branch.

Diffs this pebble's branch against the commit it was dispatched from (the pebble's base SHA --
the correct isolation boundary: the branch may already carry earlier, unrelated pebbles' commits
on top of main, and those are not this change's doing). Counts the changed protocol files (the
pool contract, the disclosure circuit and the adjudicator contract) among the files this pebble's
own commits touch, and prints `{"changed_protocol_files": N}`; exits 0 only when N == 0.

Override the base with the GIT_BASE env var (a commit-ish); defaults to this pebble's recorded
base SHA.
"""

from __future__ import annotations

import json
import os
import subprocess


# arn-2fd's base SHA (the commit this pebble's work was dispatched from).
DEFAULT_BASE = "c89dda3f9331abc042a80775133e08607d0e2914"


def run(cmd: list[str]) -> str:
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        joined = " ".join(cmd)
        raise RuntimeError("command failed (exit " + str(p.returncode) + "): " + joined)
    return p.stdout


def main() -> int:
    base = os.environ.get("GIT_BASE", DEFAULT_BASE)

    # This pebble's own changes: every commit it added on top of its base, plus any uncommitted
    # working-tree changes (git diff <base> --name-only diffs the base against the working tree,
    # so it covers both committed and uncommitted changes in one call).
    changed = run(["git", "diff", base, "--name-only"])
    changed_files = [f for f in changed.splitlines() if f.strip()]

    # The protocol files this pebble must NOT change (c6): the pool contract (the pool's
    # PrivacyPool, in the lib/armada-poc submodule), the disclosure circuit (armada-circuits'
    # NullifierDisclosure.circom) and the adjudicator contract (src/ArmadaNitroAdjudicator.sol).
    protocol_patterns = [
        "lib/armada-poc",  # the pool contract (the pool's PrivacyPool lives in this submodule)
        "armada-circuits",  # the disclosure circuit (armada-circuits' NullifierDisclosure.circom)
        "src/ArmadaNitroAdjudicator.sol",  # the adjudicator contract
    ]
    changed_protocol_files = 0
    for f in changed_files:
        for pat in protocol_patterns:
            if pat in f:
                changed_protocol_files += 1
                break

    print(json.dumps({"changed_protocol_files": changed_protocol_files}))
    return 0 if changed_protocol_files == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
