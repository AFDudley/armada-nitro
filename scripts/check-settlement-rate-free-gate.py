#!/usr/bin/env python3
"""arn-5db acceptance gate (metamorphic pair): proves the forge suite itself enforces E16 S6.

The rule (docs/tasks/E16-adjudicator-hardening.md): the adjudicator imports no ERC-4626 interface
and calls no exchange-rate function. Today that rule was checked only by a standalone script that
`forge test` never ran; this gate instead makes `forge test` the enforcement point.

The gate runs in a scratch copy of the repo so the real worktree is untouched:
  before: run `forge test` in the scratch copy with the real adjudicator source -> must PASS.
  after:  add a forbidden name (import IERC4626 + call convertToAssets) into the scratch copy's
           adjudicator source, re-run `forge test` -> must FAIL.

`forge test` (run in the scratch copy) is the checker that catches the violation: the S6 test
asserts the adjudicator's import closure and bytecode are free of ERC-4626, so injecting a rate call
flips the suite from pass to fail. The gate exits 0 only when the before passes and the after fails.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile

# The S6 test that enforces the rule; it is the forge-suite checker the gate points at.
TEST_CONTRACT = "SettlementRateFreeTest"

# Repo paths a minimal, runnable forge project needs.
_PROJECT_PATHS = [
    "foundry.toml",
    "src",
    "test",
    "lib",
    "script",
    "env",
]


def _run_forge_test(scratch: str) -> int:
    """Run the S6 test in `scratch`; return the forge exit code (0 = pass, != 0 = fail)."""
    result = subprocess.run(
        ["forge", "test", "--match-contract", TEST_CONTRACT],
        cwd=scratch,
    )
    return result.returncode


def _inject_forbidden_name(scratch: str) -> None:
    """Add IERC4626 + convertToAssets to the scratch copy's adjudicator, so `forge test` must fail."""
    adjudicator = os.path.join(scratch, "src", "ArmadaNitroAdjudicator.sol")
    with open(adjudicator, "r", encoding="utf-8") as f:
        source = f.read()
    import_line = "import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';\n"
    # Inject the import after the pragma line; inject a rate call into the main contract's constructor path
    # so the deployed bytecode contains a PUSH4 of convertToAssets.
    marker = "pragma solidity 0.8.17;\n"
    if import_line not in source:
        source = source.replace(marker, marker + import_line, 1)
    # Add a rate call guarded by a helper so it appears in the adjudicator's bytecode.
    helper = (
        "\n    // scratch: injected ERC-4626 rate call, used only to prove the forge suite flips\n"
        "    function _scratchRateCall() public view returns (uint256) {\n"
        "        address vaultAddr = address(0xA55E7);\n"
        "        return IERC4626(vaultAddr).convertToAssets(1);\n"
        "}"
    )
    # Insert the helper into the ArmadaNitroAdjudicator contract body.
    if "_scratchRateCall" not in source:
        # Find the first '{' after the contract declaration and insert the helper there.
        idx = source.index("contract ArmadaNitroAdjudicator")
        # Insert after the contract's opening brace.
        brace = source.index("{", idx)
        source = source[: brace + 1] + "\n" + helper + source[brace + 1 :]
    with open(adjudicator, "w", encoding="utf-8") as f:
        f.write(source)


def main() -> None:
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    with tempfile.TemporaryDirectory(prefix="arn-5db-scratch-") as scratch:
        for path in _PROJECT_PATHS:
            src_path = os.path.join(repo_root, path)
            dst_path = os.path.join(scratch, path)
            if not os.path.exists(src_path):
                continue
            if os.path.isdir(src_path):
                shutil.copytree(src_path, dst_path, dirs_exist_ok=True)
            else:
                shutil.copy(src_path, dst_path)

        # before: real adjudicator source -> forge test passes.
        before_rc = _run_forge_test(scratch)
        # after: inject a forbidden name -> forge test fails.
        _inject_forbidden_name(scratch)
        after_rc = _run_forge_test(scratch)

        before_ok = before_rc == 0
        after_failed = after_rc != 0
        print(f"before (real source): forge test {'passed' if before_ok else 'FAILED'} (rc={before_rc})")
        print(
            f"after (injected convertToAssets): forge test {'failed as expected' if after_failed else 'passed (unexpected)'} (rc={after_rc})"
        )

        # c2 holds when the suite passes on the real source and fails once a forbidden name is present.
        if before_ok and after_failed:
            print("gate: PASS (monotonicity holds: pass -> fail)")
            sys.exit(0)
        else:
            print(
                "gate: FAIL (expected pass->fail, got before=%s after=%s)"
                % ("pass" if before_ok else "fail", "fail" if after_failed else "pass")
            )
            sys.exit(1)


if __name__ == "__main__":
    main()
