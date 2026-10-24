#!/usr/bin/env python3
"""stack/scripts/test_verify_r2_deposit_conserves.py — proves verify-r2-deposit-conserves.py's
compute_outcome against synthetic job results, the three verdicts the real fixturenet cannot
all produce on today's contract (only ERROR is reachable until the adjudicator rewrite lands;
FAIL and PASS are proved here against hand-built inputs instead). Run directly: no fixturenet,
no network, no Docker -- a pure function, in under a second.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "verify_r2_deposit_conserves",
    Path(__file__).resolve().parent / "verify-r2-deposit-conserves.py",
)
assert _SPEC is not None and _SPEC.loader is not None
_MODULE = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_MODULE)
compute_outcome = _MODULE.compute_outcome


def check(name: str, job_result: dict[str, object], expected_result: str) -> None:
    outcome = compute_outcome(job_result)
    assert (
        outcome["result"] == expected_result
    ), f"{name}: expected result={expected_result!r}, got {outcome['result']!r} (full outcome: {outcome!r})"
    print(f"{name}: PASS (compute_outcome returned result={outcome['result']!r})")


def main() -> int:
    # ERROR: the deposit reverted. balance_fell is irrelevant -- revert takes priority, since a
    # reverted call never reaches the unshield path and proves nothing about conservation.
    check(
        "deposit reverts",
        {
            "balanceOf_before": 100,
            "balanceOf_after": 100,
            "depositFromNote": "revert",
            "balance_fell": False,
            "transactionHash": "0xabc",
            "revertData": "0x",
        },
        "ERROR",
    )

    # FAIL: the deposit succeeded and the pool's balance fell (today's real departure item 1
    # shape, once the setup/send bugs ahead of it are fixed and the deposit itself goes through).
    check(
        "deposit succeeds, balance falls",
        {
            "balanceOf_before": 100,
            "balanceOf_after": 0,
            "depositFromNote": "ok",
            "balance_fell": True,
            "transactionHash": "0xdef",
            "revertData": "",
        },
        "FAIL",
    )

    # PASS: the deposit succeeded and the pool's balance did not fall (the rewrite's own target
    # shape -- notedValue_conserved holds).
    check(
        "deposit succeeds, balance conserved",
        {
            "balanceOf_before": 100,
            "balanceOf_after": 100,
            "depositFromNote": "ok",
            "balance_fell": False,
            "transactionHash": "0x123",
            "revertData": "",
        },
        "PASS",
    )

    print("all three verdict paths proved")
    return 0


if __name__ == "__main__":
    sys.exit(main())
