#!/usr/bin/env python3
"""c2 (test-detects-missing-guard): the reentrancy test is a true detector of the holdingsLock
per-channel guard. It must PASS on the current code (guard present) and FAIL on a throwaway
checkout of the commit immediately before holdingsLock was added (32ad5e5^, guard absent).

Metamorphic monotonicity check: the result gets strictly worse without the guard — pass with it,
fail without it.

The runner parses the whole stdout of this command with json.loads, so only the final JSON object
goes to stdout; forge's own output is forwarded to stderr.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The commit that added the per-channel reentrancy guard (arn-521). The guard-absent tree is its
# parent.
GUARD_COMMIT = "32ad5e5"
GUARD_ABSENT = "32ad5e5^"
TEST_PATH = "test/ReentryDeposit.t.sol"


def run_forge(root: str) -> tuple[int, str]:
    cmd = ["forge", "test", "--match-path", TEST_PATH, "-vvv"]
    result = subprocess.run(cmd, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return result.returncode, result.stdout.decode(errors="replace")


def main() -> int:
    # With the guard present (current code), the test must PASS.
    rc_with, out_with = run_forge(REPO_ROOT)
    passed_with = rc_with == 0

    # Without the guard (throwaway checkout at 32ad5e5^), the same test must FAIL.
    # The test file did not exist before the guard commit, so copy the current test into the
    # throwaway tree.
    with tempfile.TemporaryDirectory() as td:
        subprocess.run(
            ["git", "worktree", "add", td, GUARD_ABSENT],
            cwd=REPO_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        shutil.copyfile(os.path.join(REPO_ROOT, TEST_PATH), os.path.join(td, TEST_PATH))
        rc_without, out_without = run_forge(td)
        passed_without = rc_without == 0
        if passed_without:
            print(f"unexpected: test PASSED on {GUARD_ABSENT}", file=sys.stderr)
        subprocess.run(
            ["git", "worktree", "remove", "-f", td],
            cwd=REPO_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    # Strictly worse without the guard: pass with, fail without.
    ok = passed_with and (not passed_without)
    print(
        json.dumps(
            {
                "pass_with_guard": passed_with,
                "fail_without_guard": not passed_without,
                "verdict": "pass" if ok else "fail",
            }
        )
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
