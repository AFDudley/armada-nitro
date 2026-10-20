#!/usr/bin/env bash
# N4 (request clause c10): the existing forge test suite stays green after adding
# ZkForceMoveApp (no asset, pool, nitro, or adjudicator file was touched).
#
# Runs the whole `forge test` suite with --json, counts tests whose status is neither
# "Success" nor "Skipped" (a handful of watchtower per-asset-payout tests need a live
# fork and are self-skipping without one; skipped is not failed), and prints one JSON
# line: {"total": N, "skipped": N, "failed": N}. Exits 0 iff failed == 0.
set -uo pipefail
cd "$(dirname "$0")/.."

FORGE_JSON=$(forge test --json 2>/tmp/check_forge_suite.stderr)
RC=$?

if [ -s /tmp/check_forge_suite.stderr ]; then
    echo "=== forge stderr ===" >&2
    cat /tmp/check_forge_suite.stderr >&2
fi

if [ $RC -ne 0 ] && [ -z "$FORGE_JSON" ]; then
    # forge itself failed to run (e.g. a compile error) before producing any JSON.
    echo '{"total": 0, "skipped": 0, "failed": 1}'
    exit 1
fi

python3 - "$FORGE_JSON" << 'PY'
import json
import sys

raw = sys.argv[1]
suites = json.loads(raw) if raw.strip() else {}

total = 0
skipped = 0
failed = 0
failing_names = []
for suite_name, suite in suites.items():
    for test_name, result in suite.get("test_results", {}).items():
        total += 1
        status = result.get("status")
        if status == "Success":
            continue
        if status == "Skipped":
            skipped += 1
            continue
        failed += 1
        failing_names.append(f"{suite_name}:{test_name}")

if failing_names:
    print("failing tests:", failing_names, file=sys.stderr)

print(json.dumps({"total": total, "skipped": skipped, "failed": failed}))
sys.exit(0 if failed == 0 else 1)
PY
exit $?
