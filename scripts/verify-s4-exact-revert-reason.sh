#!/usr/bin/env bash
# arn-2e6 (E16 S4, clause c2): in that same two-asset channel, the all-assets
# exit `transferAllAssets` reverts as a whole with the blocked token's own
# message 'RevertingTransferToken: transfer blocked'. Proven by the forge test
# test_transferAllAssets_revertsAsWhole_whenPairedTokenReverts, which now
# expects that exact revert reason, not any bare revert.
set -uo pipefail
cd "$(dirname "$0")/.."

FORGE_BIN="$(command -v forge || echo /home/rix/.foundry/bin/forge)"

# The test deploys contracts from the out/ artifact directory via deployCode;
# a full build is required first so the artifacts exist (the worktree's out/
# is a git-ignored build cache, so build it here to keep the script self-contained.
"$FORGE_BIN" build >/dev/null 2>&1

out=$("$FORGE_BIN" test test/PerAssetExitS4.t.sol --match-test 'test_transferAllAssets_revertsAsWhole_whenPairedTokenReverts' 2>/dev/null)
if echo "$out" | grep -qE '\[PASS\] test_transferAllAssets_revertsAsWhole_whenPairedTokenReverts'; then
    echo '{"passed": true}'
else
    echo '{"passed": false}'
fi
exit 0
