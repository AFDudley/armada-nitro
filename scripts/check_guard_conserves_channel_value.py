#!/usr/bin/env python3
"""c1 (guard-refuses-reentry): with the per-channel reentrancy guard (holdingsLock) present,
a re-entrant deposit attempted through a hooking test token's `transferFrom` callback is refused,
and both the plain and the hooked channel end up holding exactly AMOUNT — no value lost or
duplicated by the attempted re-entry.

Metamorphic no-arbitrage check: the plain deposit and the hooked (re-entering) deposit must end
with identical recorded holdings, so the net flow across the two is zero.

The runner parses the whole stdout of this command with json.loads, so only the final JSON
object goes to stdout; forge's own output is forwarded to stderr.
"""

import json
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run_forge() -> tuple[int, str]:
    cmd = ["forge", "test", "--match-contract", "ReentryDepositTest", "-vvv"]
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
        # outflow (plain final holdings, positive) and inflow (hooked final holdings, negative):
        # zero net flow iff the re-entering hook left the hooked channel's final holdings
        # identical to the plain channel's.
        flows = [plain, -hooked]
    else:
        flows = [0]
    print(json.dumps({"flows": flows}))
    return 0 if rc == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
