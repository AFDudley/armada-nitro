#!/usr/bin/env python3
"""Demonstrate that the security tests discriminate: each one fails against the cheat it exists to catch.

Each arm applies one intent-driven mutant -- a plausible wrong implementation, not a random syntax
change -- to a throwaway copy of the tree (lib/ is symlinked; the working tree is never modified, so
there is no restore step to lose). An arm is:

  KILLED        the mutant compiles and every named test fails against it (the tests discriminate);
  SURVIVED      the mutant compiles and some named test still passes (that test proves nothing);
  INCONCLUSIVE  the mutation did not take effect (snippet not found exactly once) or the mutant does
                not compile -- no verdict was computed, so none is reported.

The negative control runs the same tests on an unmutated copy; they must all pass, otherwise a kill
could be the harness breaking the build rather than the tests catching the cheat.

Usage (repository root, forge on PATH):  python3 tools/discrimination.py [arm-name ...]
Exit status: 0 iff the control passes and every selected arm is KILLED.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COPIED = ("src", "test", "script", "foundry.toml")


@dataclass(frozen=True)
class Arm:
    name: str
    intent: str
    file: str
    find: str
    replace: str
    tests: tuple[str, ...]


ARMS: tuple[Arm, ...] = (
    Arm(
        name="deposit-binding-dropped",
        intent="depositFromNote credits whatever channel the submitter names, ignoring the proof's adaptParams",
        file="src/ArmadaNitroAdjudicator.sol",
        find="transaction.boundParams.adaptParams == depositBinding(channelId, expectedHeld)",
        replace="true",
        tests=("test_depositFromNote_rejectsUnshieldBoundToAnotherChannel",),
    ),
    Arm(
        name="expected-held-ignored",
        intent="a deposit signed against an older holding lands on top of later deposits",
        file="src/ArmadaNitroAdjudicator.sol",
        find="require(held == expectedHeld, 'held != expectedHeld');",
        replace="",
        tests=("test_depositFromNote_rejectsStaleExpectedHeld",),
    ),
    Arm(
        name="shield-payout-made-public",
        intent="a SHIELD allocation is paid as a public transfer to the npk-as-address instead of a fresh note",
        file="src/ArmadaNitroAdjudicator.sol",
        find="if (allocation.allocationType == SHIELD) {",
        replace="if (false) {",
        tests=(
            "test_cooperativeClose_shieldsUserNoteAndPaysCustodian",
            "test_forceClose_userExitsToNoteWhenHubStopsResponding",
        ),
    ),
    Arm(
        name="contract-signatures-ignored",
        intent="go-nitro's ECDSA-only recovery: a custodian participant's delegate signature never counts",
        file="src/nitro/libraries/NitroUtils.sol",
        find="if (participant.code.length == 0) return false;",
        replace="return false;",
        tests=(
            "test_cooperativeClose_shieldsUserNoteAndPaysCustodian",
            "test_forceClose_userExitsToNoteWhenHubStopsResponding",
            "test_staleHubChallenge_isOverriddenByUsersLatestState",
        ),
    ),
    Arm(
        name="eip1271-gas-uncapped",
        intent="the EIP-1271 probe forwards all gas, so a hostile participant can exhaust a counterparty's challenge",
        file="src/nitro/libraries/NitroUtils.sol",
        find="staticcall(gasLimit, participant",
        replace="staticcall(gas(), participant",
        tests=("test_hostileContractParticipant_cannotExhaustACounterpartysChallenge",),
    ),
    Arm(
        name="revocation-immediate",
        intent="revoking a delegate takes effect at once, so states it signed become unprovable before they can be registered",
        file="src/HubCustodian.sol",
        find="uint64 revokedAt = uint64(block.timestamp + revocationDelay);",
        replace="uint64 revokedAt = uint64(block.timestamp);",
        tests=(
            "test_revokeDelegate_takesEffectAfterRevocationDelay",
            "test_revokedDelegate_statesRegisteredDuringDelayStillSettle",
        ),
    ),
    Arm(
        name="operation-nonce-unbound",
        intent="the group signature does not cover the nonce, so an executed operation can be replayed",
        file="src/HubCustodian.sol",
        find="address(this), nonce_, target",
        replace="address(this), uint256(0), target",
        tests=("test_execute_rejectsReplayedSignature",),
    ),
)


def make_copy(dest: Path) -> None:
    for name in COPIED:
        src = ROOT / name
        if src.is_dir():
            shutil.copytree(src, dest / name)
        else:
            shutil.copy2(src, dest / name)
    (dest / "lib").symlink_to(ROOT / "lib")
    (dest / "deployments").mkdir()


def run(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)


def test_statuses(tree: Path, tests: tuple[str, ...]) -> dict[str, str] | None:
    """Status per named test ('Success'/'Failure'), or None if forge produced no result."""
    pattern = "^(" + "|".join(tests) + r")\(\)$"
    proc = run(["forge", "test", "--match-test", pattern, "--json"], tree)
    try:
        report = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
    statuses: dict[str, str] = {}
    for suite in report.values():
        for signature, result in suite["test_results"].items():
            statuses[signature.removesuffix("()")] = result["status"]
    return statuses


def evaluate(arm: Arm | None, tests: tuple[str, ...]) -> dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="discrimination-") as tmp:
        tree = Path(tmp)
        make_copy(tree)
        if arm is not None:
            target = tree / arm.file
            text = target.read_text()
            occurrences = text.count(arm.find)
            if occurrences != 1:
                return {"verdict": "INCONCLUSIVE", "reason": f"snippet found {occurrences} times, expected 1"}
            target.write_text(text.replace(arm.find, arm.replace))
        build = run(["forge", "build"], tree)
        if build.returncode != 0:
            return {"verdict": "INCONCLUSIVE", "reason": "does not compile", "stderr": build.stderr[-2000:]}
        statuses = test_statuses(tree, tests)
        if statuses is None or set(statuses) != set(tests):
            return {
                "verdict": "INCONCLUSIVE",
                "reason": "forge did not report every named test",
                "statuses": statuses,
            }
        if arm is None:
            verdict = "PASS" if all(s == "Success" for s in statuses.values()) else "FAIL"
        else:
            verdict = "KILLED" if all(s == "Failure" for s in statuses.values()) else "SURVIVED"
        return {"verdict": verdict, "statuses": statuses}


def main(argv: list[str]) -> int:
    selected = [a for a in ARMS if not argv or a.name in argv]
    unknown = set(argv) - {a.name for a in ARMS}
    if unknown:
        print(f"unknown arm(s): {sorted(unknown)}", file=sys.stderr)
        return 2

    all_tests = tuple(sorted({t for a in selected for t in a.tests}))
    control = evaluate(None, all_tests)
    results: dict[str, object] = {"negative-control": control}
    for arm in selected:
        results[arm.name] = {"intent": arm.intent, **evaluate(arm, arm.tests)}

    print(json.dumps(results, indent=2))
    ok = control["verdict"] == "PASS" and all(
        results[a.name]["verdict"] == "KILLED"
        for a in selected  # type: ignore[index]
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
