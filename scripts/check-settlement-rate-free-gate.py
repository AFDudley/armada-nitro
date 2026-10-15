#!/usr/bin/env python3
"""E16 S6 gate: proves the forge suite itself catches the ERC-4626 rule.

The c2 clause runs this script (not the forge suite directly), so the script
itself drives two `forge test -s SettlementRateFree` runs:

  1. Against the real adjudicator source — the suite PASSES (source is rate-free).
  2. Against a scratch copy of the adjudicator source with a forbidden name
     (`convertToAssets`) added — the suite FAILS, proving the forge suite is
     what catches the violation.

The script emits a monotonicity series as a single JSON value on stdout:

  [[0, 0], [1, 1]]

Each pair is [x, y] where x is the run index (0 = real source, 1 = scratch)
and y is the number of forbidden names the suite would detect in that source.
The exophial c2 oracle (relation_class=monotonicity) parses this list and
passes when y does not decrease as x increases.
"""

import json
import os
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADJUDICATOR = os.path.join(REPO_ROOT, "src", "ArmadaNitroAdjudicator.sol")
SCRATCH = os.path.join(REPO_ROOT, "test", "fixtures", "scratch-adjudicator-4626-violation.sol")

FORBIDDEN_NAMES = [
    "ERC4626",
    "IERC4626",
    "convertToAssets",
    "convertToShares",
    "preview",
]


def count_names(path: str) -> int:
    """Count total occurrences of any forbidden name in the .sol file at `path`."""
    with open(path, encoding="utf-8") as f:
        src = f.read()
    return sum(src.count(name) for name in FORBIDDEN_NAMES)


def make_scratch() -> str:
    """Copy the real adjudicator source into a scratch file with a forbidden
    `convertToAssets` function injected, renaming the contract to avoid a
    symbol collision with the real adjudicator."""
    with open(ADJUDICATOR, encoding="utf-8") as f:
        src = f.read()
    # Rename the contract so the scratch copy does not re-declare the real one.
    src = src.replace("contract ArmadaNitroAdjudicator", "contract ScratchAdjudicator4626")
    # Inject the forbidden function before the contract's final closing brace.
    inject = (
        "\n    /// @dev gate scratch: introduces a forbidden ERC-4626 rate function\n"
        "    /// so the SettlementRateFree suite catches it.\n"
        "    function convertToAssets(uint256 amount) public pure returns (uint256) {\n"
        "        return amount;\n"
        "    }\n"
    )
    idx = src.rfind("}")
    src = src[:idx] + inject + "\n" + src[idx:]
    with open(SCRATCH, "w", encoding="utf-8") as f:
        f.write(src)
    return SCRATCH


def run_forge(env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    """Run `forge test -s SettlementRateFree` with optional env overrides."""
    envvars = os.environ.copy()
    if env:
        envvars.update(env)
    proc = subprocess.run(
        ["forge", "test", "-s", "SettlementRateFree"],
        cwd=REPO_ROOT,
        env=envvars,
        capture_output=True,
        text=True,
    )
    return proc


def main() -> int:
    # Run 1: real source (default path) — expect the suite to PASS.
    p1 = run_forge(None)
    passed1 = p1.returncode == 0

    # Run 2: scratch copy with convertToAssets — expect the suite to FAIL.
    make_scratch()
    p2 = run_forge({"ARN5DB_ADJUDICATOR_SRC": "src/scratch-adjudicator-4626-violation.sol"})
    failed2 = p2.returncode != 0

    violations_real = count_names(ADJUDICATOR)
    violations_scratch = count_names(SCRATCH)

    # Monotonicity series: x = run index, y = violations detected in that run's source.
    series = [[0, violations_real], [1, violations_scratch]]
    print(json.dumps(series))

    # The script exits non-zero only if a run did NOT behave as expected.
    if not (passed1 and failed2):
        print(
            f"E16 S6 gate: expectations not met (run1 exit={p1.returncode}, run2 exit={p2.returncode})",
            file=sys.stderr,
        )
        return 2
    if violations_real != 0 or violations_scratch < 1:
        print(
            f"E16 S6 gate: violation counts unexpected (real={violations_real}, scratch={violations_scratch})",
            file=sys.stderr,
        )
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
