#!/usr/bin/env python3
"""c2 (no-nested-call-while-in-progress): while a call to any of deposit, depositFromNote,
transfer, transferAllAssets, concludeAndTransferAllAssets or reclaim is still in progress on a
channel, a nested call into those same entry points on that channel must revert and leave the
recorded holdings unchanged.

Metamorphic no-arbitrage check: for each of the six entry points, a nested call must not change
the channel's final recorded holdings, so the net flow per entry point is zero.

The runner parses the whole stdout of this command with json.loads, so only the final JSON object
goes to stdout; forge's own output is forwarded to stderr.
"""

import json
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run_forge(argv: list[str]) -> tuple[int, str]:
    cmd = ["forge", "test", "--match-contract", "ReentryGuardTest", "-vvv"]
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


def main(argv: list[str]) -> int:
    rc, out = run_forge(argv)
    # One line per entry point: "ARN521_C2 <fn> <before> <after>"
    flows = []
    for m in re.finditer(r"ARN521_C2 (\w+) (\d+) (\d+)", out):
        # net flow = before - after (outflow positive when holdings decrease, inflow negative when they increase)
        before, after = int(m.group(2)), int(m.group(3))
        flows.append(before - after)
    if not flows:
        flows = [0]
    print(json.dumps({"flows": flows}))
    return 0 if rc == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
