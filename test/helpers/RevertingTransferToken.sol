// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

/**
 * @dev arn-7de: a channel asset whose `transfer` always reverts, used by
 * `scripts/check-e2e-settle-per-asset.py` to prove `FixturenetScenario.s.sol`'s `settle()`
 * falls back to per-asset `transfer(assetIndex, ...)` (MultiAssetHolder.sol) when
 * `transferAllAssets` reverts on this asset. `transferFrom` is left untouched (standard
 * ERC20), so `MultiAssetHolder.deposit`'s `safeTransferFrom` still funds the channel
 * normally -- only the payout-side `transfer` call blocks, matching "the token itself
 * blocks the transfer" from the originating report.
 */
contract RevertingTransferToken is ERC20 {
    constructor(uint256 initialSupply) ERC20('Reverting Token', 'REV') {
        _mint(msg.sender, initialSupply);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        revert('RevertingTransferToken: transfer blocked');
    }
}
