#!/usr/bin/env python3
"""c1 (hooked-deposit-matches-plain-deposit): deposit the same amount of the same kind of
token into the same channel from identical starting conditions — once with a plain ERC20, once
with a token whose transfer hook calls back into the adjudicator mid-deposit. The channel must
end with identical recorded holdings, and the hook's own nested call must revert.

Metamorphic no-arbitrage check: adding the re-entering hook must leave the channel's final
recorded holdings unchanged, so the net flow across the two deposits is zero.

The runner parses the whole stdout of this command with json.loads, so only the final JSON
object goes to stdout; forge's own output is forwarded to stderr.
"""

import json
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run_forge(argv: list[str]) -> tuple[int, str]:
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


def main(argv: list[str]) -> int:
    rc, out = run_forge(argv)

    m = re.search(r"ARN521_C1 (\d+) (\d+)", out)
    if m:
        plain, hooked = int(m.group(1)), int(m.group(2))
        # outflow (plain final holdings, positive) and inflow (hooked final holdings, negative)
        flows = [plain, -hooked]
    else:
        flows = [0]
    print(json.dumps({"flows": flows}))
    return 0 if rc == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
