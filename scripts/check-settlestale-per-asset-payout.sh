#!/usr/bin/env bash
# arn-df2 (E16 S4, request clause c2): proves `script/WatchtowerScenario.s.sol`'s `settleStale()`
# pays every asset of a finalized two-asset channel (not only asset index 0) through its own
# `transfer(assetIndex, ...)` call, in both a run where a single combined payout covering both
# assets would have succeeded and one where it would not. See
# scripts/check-respond-per-asset-payout.sh's header for why this is a `forge test` (driving
# WatchtowerPerAssetSetup/WatchtowerScenario directly) rather than a `forge script` run, and why
# it needs a live local anvil.
#
# Prints one JSON line with the four fields the spec's acceptance test reads; exits non-zero (and
# reports sentinel values that fail the `eq` checks) if either underlying forge test regresses.
set -uo pipefail
cd "$(dirname "$0")/.."

PORT="${ANVIL_PORT:-8739}"
RPC="http://127.0.0.1:${PORT}"

if command -v ss >/dev/null 2>&1 && ss -ltn "( sport = :${PORT} )" | grep -q LISTEN; then
    echo "check-settlestale-per-asset-payout: port ${PORT} already in use; set ANVIL_PORT to a free port" >&2
    exit 1
fi

anvil --host 127.0.0.1 --port "${PORT}" --silent &
ANVIL_PID=$!
cleanup() { kill "${ANVIL_PID}" >/dev/null 2>&1; wait "${ANVIL_PID}" 2>/dev/null; }
trap cleanup EXIT

for _ in $(seq 1 60); do
    cast block-number --rpc-url "${RPC}" >/dev/null 2>&1 && break
    sleep 0.5
done

JSON_OUT=$(forge test \
    --fork-url "${RPC}" \
    --match-contract WatchtowerPerAssetPayoutCheckTest \
    --match-test 'test_settleStale_perAssetPayout_' \
    --threads 1 \
    --json 2>/dev/null)

python3 - "$JSON_OUT" << 'PY'
import json
import sys

raw = sys.argv[1]
try:
    suites = json.loads(raw)
except json.JSONDecodeError:
    suites = {}

status = {}
for suite in suites.values():
    for name, result in suite.get("test_results", {}).items():
        status[name.split("(")[0]] = result.get("status") == "Success"

feasible_ok = status.get("test_settleStale_perAssetPayout_whenCombinedWouldSucceed", False)
infeasible_ok = status.get("test_settleStale_perAssetPayout_whenCombinedWouldRevert", False)

result = {
    "combined_call_committed_when_feasible": 0 if feasible_ok else 1,
    "combined_call_committed_when_infeasible": 0 if infeasible_ok else 1,
    "per_asset_transfers_committed_when_feasible": 2 if feasible_ok else 0,
    "per_asset_transfers_committed_when_infeasible": 2 if infeasible_ok else 0,
}
print(json.dumps(result))
sys.exit(0 if (feasible_ok and infeasible_ok) else 1)
PY
exit $?
