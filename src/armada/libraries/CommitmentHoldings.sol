// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {CommitmentPreimage, IArmadaPool} from '../IArmadaPool.sol';

/**
 * @title CommitmentHoldings
 * @notice R1 rewrite component (a): the per-asset, per-channel `bytes32` commitment holdings
 * read (N1a) `ArmadaNitroAdjudicator` needs, linked into the adjudicator at deploy time so this
 * bytecode does not count against the adjudicator's own EIP-170 budget
 * (docs/tasks/R1-adjudicator-rewrite.md).
 * @dev `public`, not `internal` (an `internal` library function inlines into the caller and
 * gives no size relief). Takes the commitment value as an argument rather than adjudicator
 * storage directly -- a library function cannot read its caller's storage layout by name; the
 * caller reads `holdings[asset][channelId]` itself and passes the result in.
 */
library CommitmentHoldings {
    /// @dev N1a: the held amount behind a channel collateral commitment. Empty commitment -> 0;
    /// a set commitment reads the pool's preimage live through `preimageOf` (never a cached or
    /// passed-in amount). The pool's `uint120` value is cast to `uint256` with SafeCast.
    function heldValue(IArmadaPool pool, bytes32 commitment) public view returns (uint256) {
        if (uint256(commitment) == 0) {
            return 0;
        }
        CommitmentPreimage memory preimage = pool.preimageOf(commitment);
        return SafeCast.toUint256(int256(uint256(preimage.value)));
    }
}
