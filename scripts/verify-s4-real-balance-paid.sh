#!/usr/bin/env bash
# arn-2e6 (E16 S4, clause c1): in a two-asset channel whose second token
# (RevertingTransferToken) always reverts on transfer, the single-asset exit
# `transfer(assetIndex)` still pays out the other (good) asset, and the USDC
# payment really reached the custodian's wallet. Proven by the forge test
# test_transfer_assetIndex_paysOtherAsset_whenPairedTokenReverts, which now
# asserts the custodian's real USDC balance increased by exactly HUB_FUNDS.
set -uo pipefail
cd "$(dirname "$0")/.."

FORGE_BIN="$(command -v forge || echo /home/rix/.foundry/bin/forge)"

# The test deploys contracts from the out/ artifact directory via deployCode;
# a full build is required first so the artifacts exist (the worktree's out/
# is a git-ignored build cache, so build it here to keep the script self-contained.
"$FORGE_BIN" build >/dev/null 2>&1

out=$("$FORGE_BIN" test test/PerAssetExitS4.t.sol --match-test 'test_transfer_assetIndex_paysOtherAsset_whenPairedTokenReverts' 2>/dev/null)
if echo "$out" | grep -qE '\[PASS\] test_transfer_assetIndex_paysOtherAsset_whenPairedTokenReverts'; then
    echo '{"passed": true}'
else
    echo '{"passed": false}'
fi
exit 0
