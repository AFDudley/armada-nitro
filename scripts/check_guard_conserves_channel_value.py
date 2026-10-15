#!/usr/bin/env python3
"""c1 (guard-refuses-reentry): with the per-channel reentrancy guard (holdingsLock) present,
a re-entrant deposit made through a hooking token's transferFrom is refused by the guard, and
both channels end up holding exactly AMOUNT (no value lost or duplicated by the re-entry).

Metamorphic conservation check: the final recorded holdings of the plain and hooked channels must
both equal AMOUNT; the re-entering hook must leave the channel's final holdings unchanged.

The runner parses the whole stdout of this command with json.loads, so only the final JSON object
goes to stdout; forge's own output is forwarded to stderr.
"""

import json
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AMOUNT = 100e6  # matches AMOUNT in test/ReentryDeposit.t.sol


def run_forge() -> tuple[int, str]:
    cmd = ["forge", "test", "--match-path", "test/ReentryDeposit.t.sol", "-vvv"]
    result = subprocess.run(cmd, cwd=REPO_ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    forge_out = result.stdout.decode(errors="replace")
    forge_err = result.stderr.decode(errors="replace")
    if forge_out.strip():
        print("=== forge stdout ===", file=sys.stderr)
        print(forge_out, file=sys.stderr)
    if forge_err.strip():
        print("=== forge stderr ===", file=sys.stderr)
        print(forge_err, file=sys.stderr)
    return result.returncode, forge_out


def main() -> int:
    rc, out = run_forge()
    m = re.search(r"ARN521_C1 (\d+) (\d+)", out)
    if m:
        plain, hooked = int(m.group(1)), int(m.group(2))
        flows = [plain, -hooked]  # outflow (plain, positive), inflow (hooked, negative)
        # conservation: both final holdings must equal AMOUNT
        ok = plain == AMOUNT and hooked == AMOUNT
    else:
        flows = [0]
        ok = False
    if rc != 0:
        ok = False
    print(
        json.dumps({"flows": flows, "plain": plain, "hooked": hooked, "amount": AMOUNT, "ok": ok})
        if m
        else json.dumps({"flows": flows, "ok": ok})
    )
    return 0 if (ok and rc == 0) else 1


if __name__ == "__main__":
    sys.exit(main())
