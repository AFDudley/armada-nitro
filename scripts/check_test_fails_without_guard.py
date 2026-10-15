#!/usr/bin/env python3
"""c2 (test-detects-missing-guard): test/ReentryDeposit.t.sol must be a real detector of the
per-channel reentrancy guard (holdingsLock): it passes with the guard present and fails when the
guard is absent, instead of passing regardless (as the pre-fix version of the test did when run
against 32ad5e5^, the commit immediately before holdingsLock was added).

Metamorphic monotonicity check: moving from "guard absent" (x=0) to "guard present" (x=1) must
not make the test's result worse. The result is encoded as 1 (test passed) or 0 (test failed), so
a real detector produces the non-decreasing series [[0, 0], [1, 1]]; a test that passes either way
would produce [[0, 1], [1, 1]], which is also non-decreasing but is caught by the companion
assertion below that the "guard absent" run must actually fail.

The runner parses the whole stdout of this command with json.loads, so only the final JSON object
goes to stdout; forge's own and git's own output are forwarded to stderr.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST_PATH = "test/ReentryDeposit.t.sol"
PRE_GUARD_REV = "32ad5e5c21c6e6d391235cad9abbc8fd12fd0e00^"


def run(cmd: list[str], cwd: str) -> int:
    result = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out = result.stdout.decode(errors="replace")
    err = result.stderr.decode(errors="replace")
    if out.strip():
        print(f"=== {' '.join(cmd)} stdout ===", file=sys.stderr)
        print(out, file=sys.stderr)
    if err.strip():
        print(f"=== {' '.join(cmd)} stderr ===", file=sys.stderr)
        print(err, file=sys.stderr)
    return result.returncode


def run_forge_reentry_test(cwd: str) -> bool:
    """Returns True iff the reentrancy test passes."""
    rc = run(["forge", "test", "--match-contract", "ReentryDepositTest", "-vvv"], cwd)
    return rc == 0


def run_without_guard() -> bool:
    """Checks out the commit immediately before holdingsLock was added into a throwaway
    worktree, drops in the CURRENT test file (the one under test), and runs it there. Returns
    True iff the test passes without the guard (which it must NOT, for the test to be a real
    detector)."""
    with tempfile.TemporaryDirectory(prefix="arn-00d-no-guard-") as tmpdir:
        worktree_dir = os.path.join(tmpdir, "worktree")
        rc = run(["git", "worktree", "add", "--detach", worktree_dir, PRE_GUARD_REV], REPO_ROOT)
        if rc != 0:
            raise RuntimeError("failed to create throwaway worktree at " + PRE_GUARD_REV)
        try:
            shutil.copyfile(
                os.path.join(REPO_ROOT, TEST_PATH),
                os.path.join(worktree_dir, TEST_PATH),
            )
            return run_forge_reentry_test(worktree_dir)
        finally:
            run(["git", "worktree", "remove", "--force", worktree_dir], REPO_ROOT)


def main() -> int:
    passes_with_guard = run_forge_reentry_test(REPO_ROOT)
    passes_without_guard = run_without_guard()

    y_without_guard = 1 if passes_without_guard else 0
    y_with_guard = 1 if passes_with_guard else 0
    series = [[0, y_without_guard], [1, y_with_guard]]
    print(json.dumps({"series": series}))

    # The result must genuinely be worse without the guard: the test must pass with the guard
    # and fail without it. A test that passes in both cases (or fails in both) is not a detector.
    ok = passes_with_guard and not passes_without_guard
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
