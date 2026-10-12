#!/usr/bin/env python3
"""Guard: no adjudicator holdings-mutating entry point accepts a nested call while an earlier
call on the same channel is still in progress (design 15 I6, E16 S3).

Metamorphic check (relation: triggering a nested call into any of deposit, depositFromNote,
transfer, transferAllAssets, concludeAndTransferAllAssets or reclaim on a channel that already has
one of those six calls in progress never changes that channel's holdings, because the nested call
always reverts): runs the forge test `ReentryGuardTest`, which exercises each of the six entry
points with `holdingsLock` for the channel already set (the exact condition the reentrancy guard
added to `MultiAssetHolder`/`NitroAdjudicator`/`ArmadaNitroAdjudicator` checks), and asserts every
one of the six reverts with 'Re-entered while in progress' and leaves the channel's recorded
holdings exactly as they were before the attempt.

Exits 0 when the forge test passes (every one of the six entry points rejects the nested call);
non-zero otherwise (`forge test`'s own exit code).
"""

import os
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main(argv: list[str]) -> int:
    cmd = ["forge", "test", "--match-contract", "ReentryGuardTest"]
    if "-v" in argv or "--verbose" in argv:
        cmd.append("-vvv")
    result = subprocess.run(cmd, cwd=REPO_ROOT)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
