#!/usr/bin/env bash
# arn-bfc (E16 S4, clause c1): in a two-asset channel whose second token (RevertingTransferToken)
# always reverts on transfer, the single-asset exit `transfer(assetIndex)` still pays out the
# other (good) asset. Proven by the forge test test_transfer_assetIndex_paysOtherAsset_whenPairedTokenReverts.
set -uo pipefail
cd "$(dirname "$0")/.."

out=$(forge test test/PerAssetExitS4.t.sol --match-test 'test_transfer_assetIndex_paysOtherAsset_whenPairedTokenReverts' 2>/dev/null)
if echo "$out" | grep -qE '\[PASS\] test_transfer_assetIndex_paysOtherAsset_whenPairedTokenReverts'; then
    echo '{"other_asset_paid": true}'
else
    echo '{"other_asset_paid": false}'
fi
exit 0
