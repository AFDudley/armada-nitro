#!/usr/bin/env python3
"""arn-40f conservation oracle artifact: MultiAssetHolder._transferAsset pays out an ERC20
asset through the adjudicator, or the call reverts -- value is conserved.

This script is the `run` artifact of the two metamorphic conservation acceptance tests in
contracts/specs/derived-arn-40f.spec.json. The exophial conservation oracle
(exophial spec_oracle._relation_conservation) does NOT read a pass/fail verdict: it runs this
artifact, parses its stdout as a JSON object, and asserts the single relation
`|sum(flows)| <= tolerance` over the `flows` key. So this script MEASURES real on-chain
signed deltas and emits them as `flows`; the oracle owns the judgment.

It drives test/PayoutConservation.t.sol, which exercises the real adjudicator payout and emits,
for each token kind, three measured log lines:
  - `<label>_hdelta=<int>`   signed change of the channel holdings ledger
  - `<label>_ddelta=<int>`   signed change of the destination token balance
  - `<label>_requested=<int>` the amount the payout was asked to move

The `--token <kind>` argv selects which clause the oracle grades, and how the flows encode it:
  - c1 (`returns-false`): the payout must be refused as a whole and move nothing, so the total
    of channel holdings plus the destination balance is unchanged. flows = [hdelta, ddelta];
    sum == 0 iff that total did not change. On the fixed branch the payout reverts
    (hdelta=0, ddelta=0, sum 0). On the buggy base the ledger drops but nothing is delivered
    (hdelta=-amount, ddelta=0, sum=-amount) -- the relation fails.
  - c2 (`returns-true`, `returns-nothing`): each token must pay the full requested amount to the
    destination. flows per token = [-requested, ddelta]; sum == 0 iff the destination received
    exactly the requested amount for every token. On the fixed branch both pay
    (ddelta=+requested, sum 0). On the buggy base a no-return (USDT-like) token payout reverts
    and delivers nothing (ddelta=0), so the sum is non-zero and the relation fails.

Exits 0 once it has measured and emitted the flows for every requested token kind. It exits
non-zero (and emits no flows) only when the measurement itself could not be obtained -- a
missing forge binary or a token kind whose log lines forge never produced -- so the oracle
never grades a conservation relation over numbers that were not measured.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

_TEST_FILE = "test/PayoutConservation.t.sol"
CONTRACT = "PayoutConservationTest"

# Map each requested token kind to the Solidity test label it is measured under, and the
# conservation clause whose text the flows encode.
KIND_TO_LABEL = {
    "returns-false": "returnsFalse",  # c1: payout refused, nothing moves
    "returns-true": "returnsTrue",  # c2: standard token pays the full amount
    "returns-nothing": "returnsNothing",  # c2: USDT-like token pays the full amount
}
# c1 asks "did the holdings+destination total stay the same?"; c2 asks "did the destination
# receive the full requested amount?". Both are measured, never assumed.
C1_KINDS = frozenset({"returns-false"})


def forge_bin() -> str:
    """Resolve the forge binary: prefer one on PATH, else the foundry install."""
    forge = shutil.which("forge")
    if forge:
        return forge
    candidates = [os.path.join(os.path.expanduser("~"), ".foundry", "bin", "forge")]
    candidates += sorted(
        glob.glob(os.path.join(os.path.expanduser("~"), ".foundry", "versions", "*", "*", "forge"))
    )
    for path in candidates:
        if os.path.exists(path):
            return path
    raise FileNotFoundError("forge binary not found; install foundry or add it to PATH")


def run_forge() -> str:
    """Run the PayoutConservation tests at -vv so every test's measured log lines are printed,
    whether the test passes (the fixed branch) or an assertion fails (the buggy base)."""
    proc = subprocess.run(
        [forge_bin(), "test", _TEST_FILE, "--match-contract", CONTRACT, "-vv"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    return proc.stdout + proc.stderr


def parse_measurements(output: str) -> dict[str, dict[str, int]]:
    """Parse the `<label>_<field>=<int>` log lines into {label: {field: value}}."""
    measured: dict[str, dict[str, int]] = {}
    for match in re.finditer(r"(returns[A-Za-z]+)_(hdelta|ddelta|requested)=(-?\d+)", output):
        label, field, value = match.group(1), match.group(2), int(match.group(3))
        measured.setdefault(label, {})[field] = value
    return measured


def flows_for_kind(kind: str, fields: dict[str, int]) -> list[int]:
    """Build the signed flows for one token kind from its measured deltas.

    c1: [hdelta, ddelta] -- the signed change of (holdings + destination).
    c2: [-requested, ddelta] -- the owed amount leaves, the delivered amount arrives.
    """
    if kind in C1_KINDS:
        return [fields["hdelta"], fields["ddelta"]]
    return [-fields["requested"], fields["ddelta"]]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--token",
        action="append",
        dest="tokens",
        default=[],
        help="token kind to check (repeatable): returns-false, returns-true, returns-nothing",
    )
    args = parser.parse_args()

    if not args.tokens:
        parser.error("at least one --token kind is required")

    # Preserve request order, drop duplicates, reject an unknown kind (fail loud).
    requested: list[str] = []
    seen: set[str] = set()
    for kind in args.tokens:
        if kind not in KIND_TO_LABEL:
            sys.stderr.write(f"unknown token kind: {kind!r}\n")
            return 2
        if kind not in seen:
            seen.add(kind)
            requested.append(kind)

    output = run_forge()
    measured = parse_measurements(output)

    flows: list[int] = []
    for kind in requested:
        label = KIND_TO_LABEL[kind]
        fields = measured.get(label)
        required = ("hdelta", "ddelta") if kind in C1_KINDS else ("requested", "ddelta")
        if fields is None or any(f not in fields for f in required):
            sys.stderr.write(
                f"no measurement for token kind {kind!r} (label {label!r}); forge output:\n{output}\n"
            )
            return 1
        flows.extend(flows_for_kind(kind, fields))

    # Emit only the measured flows. The conservation oracle owns the pass/fail decision.
    print(json.dumps({"flows": flows}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
