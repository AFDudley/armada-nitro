#!/usr/bin/env python3
"""Guard: a reentering deposit hook must not change a deposit's final holdings (design 15 I6,
E16 S3).

Metamorphic check (relation: adding a re-entering transfer hook to the deposited token leaves the
channel's final recorded holdings unchanged, and the hook's own nested call into the adjudicator
fails): runs the forge test `ReentryDepositTest`, which deposits the same amount of the same kind
of token into two channels from identical starting conditions — once with a plain ERC20, once with
a token whose `transferFrom` tries to call back into `ArmadaNitroAdjudicator.deposit` on the same
channel mid-deposit — and asserts both channels end with identical recorded holdings and that the
hook's own nested call reverted.

Exits 0 when the forge test passes (the relation holds and the nested call failed); non-zero
otherwise (`forge test`'s own exit code).
"""

import os
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main(argv: list[str]) -> int:
    cmd = ["forge", "test", "--match-contract", "ReentryDepositTest"]
    if "-v" in argv or "--verbose" in argv:
        cmd.append("-vvv")
    result = subprocess.run(cmd, cwd=REPO_ROOT)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
