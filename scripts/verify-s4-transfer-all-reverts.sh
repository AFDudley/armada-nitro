#!/usr/bin/env bash
# arn-bfc (E16 S4, clause c2): in that same two-asset channel, the all-assets exit
# `transferAllAssets` reverts as a whole (no partial payout). Proven by the forge test
# test_transferAllAssets_revertsAsWhole_whenPairedTokenReverts.
set -uo pipefail
cd "$(dirname "$0")/.."

out=$(forge test test/PerAssetExitS4.t.sol --match-test 'test_transferAllAssets_revertsAsWhole_whenPairedTokenReverts' 2>/dev/null)
if echo "$out" | grep -qE '\[PASS\] test_transferAllAssets_revertsAsWhole_whenPairedTokenReverts'; then
    echo '{"transfer_all_reverted": true}'
else
    echo '{"transfer_all_reverted": false}'
fi
exit 0
