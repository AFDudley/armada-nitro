#!/usr/bin/env bash
# N3 (clause c5): no in-repo caller depends on the reverted bulk payout path --
# NitroAdjudicator's `transferAllAssets` (closed: it always reverts with 'Use
# transfer(assetIndex, ...)') or a bulk-payout-dependent use of
# `concludeAndTransferAllAssets` (now finalize-only, so a real settlement path
# must follow it with its own per-asset `transfer(assetIndex, ...)`).
#
# Scope: production code that actually drives on-chain settlement --
# script/*.sol (deploy/scenario scripts) and stack/**/*.sol, *.yml, *.py (job
# definitions and orchestration). Deliberately EXCLUDES:
#   - src/**/*.sol function DECLARATIONS (concludeAndTransferAllAssets and
#     transferAllAssets are still real entry points on the adjudicator --
#     c1/c2 require them to exist and behave a specific way, not disappear);
#   - test/**/*.t.sol: these are the oracles that PROVE the closure (c1-c4) by
#     calling the functions and asserting finalize-only / revert behavior --
#     calling a function to prove it is closed is not "depending on" it.
#
# A member-access call site (`x.transferAllAssets(` / `x.concludeAndTransferAllAssets(`,
# or the `abi.encodeCall(x.transferAllAssets,` idiom) in that scope is exactly a
# caller that would break (or silently rely on a no-op) now that the bulk path
# is closed -- which is why every real one was redirected to `conclude()` +
# per-asset `transfer(assetIndex, ...)` as part of this change.
#
# Prints one JSON line: {"bulk_path_caller_count": N, "callers": [...]}.
# Exits 0 regardless of N (the count itself is the oracle's signal); exits
# non-zero only on a script-internal error.
set -uo pipefail
cd "$(dirname "$0")/.."

PATTERN='\.(transferAllAssets|concludeAndTransferAllAssets)\s*[(,]'

callers=()
while IFS= read -r line; do
    [ -n "$line" ] && callers+=("$line")
done < <(
    grep -rEno "$PATTERN" \
        script \
        stack \
        2>/dev/null \
    | sed 's/:[^:]*$//' \
    | sort -u
)

python3 - "${callers[@]+"${callers[@]}"}" << 'PY'
import json
import sys

callers = sys.argv[1:]
print(json.dumps({"bulk_path_caller_count": len(callers), "callers": callers}))
PY
exit 0
