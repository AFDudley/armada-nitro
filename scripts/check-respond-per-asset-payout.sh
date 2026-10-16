#!/usr/bin/env bash
# arn-df2 (E16 S4, request clause c1): proves `script/WatchtowerScenario.s.sol`'s `respond()`
# pays every asset of a finalized two-asset channel through its own `transfer(assetIndex, ...)`
# call, in both a run where a single combined payout covering both assets would have succeeded
# (the second asset's token transfers fine) and one where it would not (the second asset's token
# always reverts on transfer, so `concludeAndTransferAllAssets` would revert as a whole -- see
# test/PerAssetExitS4.t.sol's `test_transferAllAssets_revertsAsWhole_whenPairedTokenReverts`).
#
# Delegates to test/WatchtowerPerAssetPayoutCheck.t.sol, which drives the real
# `WatchtowerPerAssetSetup`/`WatchtowerScenario` contracts directly (not via a separate `forge
# script` process -- a `forge script --broadcast` run aborts entirely if ANY queued transaction
# would revert on-chain, which would make the "combined call infeasible" arm impossible to
# exercise) and asserts, via `vm.expectCall`, the exact number of calls made to each payout
# selector. A fresh local anvil backs the run (never the shared fixturenet) because
# `WatchtowerPerAssetSetup.setup` needs a live RPC to place the Poseidon precompile.
#
# Prints one JSON line with the four fields the spec's acceptance test reads; exits non-zero (and
# reports sentinel values that fail the `eq` checks) if either underlying forge test regresses.
set -uo pipefail
cd "$(dirname "$0")/.."

PORT="${ANVIL_PORT:-8738}"
RPC="http://127.0.0.1:${PORT}"

if command -v ss >/dev/null 2>&1 && ss -ltn "( sport = :${PORT} )" | grep -q LISTEN; then
    echo "check-respond-per-asset-payout: port ${PORT} already in use; set ANVIL_PORT to a free port" >&2
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
    --match-test 'test_respond_perAssetPayout_' \
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

feasible_ok = status.get("test_respond_perAssetPayout_whenCombinedWouldSucceed", False)
infeasible_ok = status.get("test_respond_perAssetPayout_whenCombinedWouldRevert", False)

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
