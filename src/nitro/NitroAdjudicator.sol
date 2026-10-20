// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';
import {NitroUtils} from './libraries/NitroUtils.sol';
import {INitroAdjudicator} from './interfaces/INitroAdjudicator.sol';
import {ForceMove} from './ForceMove.sol';
import {IForceMoveApp} from './interfaces/IForceMoveApp.sol';
import {MultiAssetHolder} from './MultiAssetHolder.sol';

/**
 * @dev The NitroAdjudicator contract extends MultiAssetHolder and ForceMove
 */
contract NitroAdjudicator is INitroAdjudicator, ForceMove, MultiAssetHolder {
    /**
     * @notice Finalizes a channel according to the given candidate, and liquidates all assets for the channel.
     * @dev Finalizes a channel according to the given candidate, and liquidates all assets for the channel.
     * @param fixedPart Data describing properties of the state channel that do not change with state updates.
     * @param candidate Variable part of the state to change to.
     */
    function concludeAndTransferAllAssets(
        FixedPart memory fixedPart,
        SignedVariablePart memory candidate
    ) public virtual {
        bytes32 channelId = _conclude(fixedPart, candidate);

        // guard: no nested call may run on this channel while this conclude is in progress.
        require(holdingsLock[channelId] == 0, 'Re-entered while in progress');
        holdingsLock[channelId] += 1;
        _transferAllAssetsBody(channelId, candidate.variablePart.outcome, bytes32(0));
        holdingsLock[channelId] -= 1;
    }

    /**
     * @notice Liquidates all assets for the channel
     * @dev Liquidates all assets for the channel
     * @param channelId Unique identifier for a state channel
     * @param outcome An array of SingleAssetExit[] items.
     * @param stateHash stored state hash for the channel
     */
    function transferAllAssets(
        bytes32 channelId,
        Outcome.SingleAssetExit[] memory outcome,
        bytes32 stateHash
    ) public virtual {
        // guard: no nested call may run on this channel while this transfer is in progress.
        require(holdingsLock[channelId] == 0, 'Re-entered while in progress');
        holdingsLock[channelId] += 1;
        _transferAllAssetsBody(channelId, outcome, stateHash);
        holdingsLock[channelId] -= 1;
    }

    function _transferAllAssetsBody(
        bytes32 channelId,
        Outcome.SingleAssetExit[] memory outcome,
        bytes32 stateHash
    ) internal {
        // checks
        _requireChannelFinalized(channelId);
        _requireMatchingFingerprint(stateHash, NitroUtils.hashOutcome(outcome), channelId);

        // computation
        bool allocatesOnlyZerosForAllAssets = true;
        Outcome.SingleAssetExit[] memory exit = new Outcome.SingleAssetExit[](outcome.length);
        uint256[] memory initialHoldings = new uint256[](outcome.length);
        uint256[] memory totalPayouts = new uint256[](outcome.length);
        for (uint256 assetIndex = 0; assetIndex < outcome.length; assetIndex++) {
            Outcome.SingleAssetExit memory assetOutcome = outcome[assetIndex];
            Outcome.Allocation[] memory allocations = assetOutcome.allocations;
            address asset = outcome[assetIndex].asset;
            initialHoldings[assetIndex] = heldValue(asset, channelId);
            (
                Outcome.Allocation[] memory newAllocations,
                bool allocatesOnlyZeros,
                Outcome.Allocation[] memory exitAllocations,
                uint256 totalPayoutsForAsset
            ) = compute_transfer_effects_and_interactions(
                    initialHoldings[assetIndex],
                    allocations,
                    new uint256[](0)
                );
            if (!allocatesOnlyZeros) allocatesOnlyZerosForAllAssets = false;
            totalPayouts[assetIndex] = totalPayoutsForAsset;
            outcome[assetIndex].allocations = newAllocations;
            exit[assetIndex] = Outcome.SingleAssetExit(
                asset,
                assetOutcome.assetMetadata,
                exitAllocations
            );
        }

        // effects
        for (uint256 assetIndex = 0; assetIndex < outcome.length; assetIndex++) {
            address asset = outcome[assetIndex].asset;
            holdings[asset][channelId] = bytes32(uint256(holdings[asset][channelId]) - totalPayouts[assetIndex]);
            emit AllocationUpdated(
                channelId,
                asset,
                initialHoldings[assetIndex],
                heldValue(asset, channelId)
            );
        }

        if (allocatesOnlyZerosForAllAssets) {
            delete statusOf[channelId];
        } else {
            _updateFingerprint(channelId, stateHash, NitroUtils.hashOutcome(outcome));
        }

        // interactions
        _executeExit(exit);
    }

    /**
     * @notice Encodes application-specific rules for a particular ForceMove-compliant state channel.
     * @dev Encodes application-specific rules for a particular ForceMove-compliant state channel.
     * @param fixedPart Fixed part of the state channel.
     * @param proof Variable parts of the states with signatures in the support proof. The proof is a validation for the supplied candidate.
     * @param candidate Variable part of the state to change to. The candidate state is supported by proof states.
     */
    function stateIsSupported(
        FixedPart calldata fixedPart,
        SignedVariablePart[] calldata proof,
        SignedVariablePart calldata candidate
    ) external view returns (bool, string memory) {
        return
            IForceMoveApp(fixedPart.appDefinition).stateIsSupported(
                fixedPart,
                recoverVariableParts(fixedPart, proof),
                recoverVariablePart(fixedPart, candidate)
            );
    }

    /**
     * @notice Executes an exit by paying out assets and calling external contracts
     * @dev Executes an exit by paying out assets and calling external contracts
     * @param exit The exit to be paid out.
     */
    function _executeExit(Outcome.SingleAssetExit[] memory exit) internal {
        for (uint256 assetIndex = 0; assetIndex < exit.length; assetIndex++) {
            _executeSingleAssetExit(exit[assetIndex]);
        }
    }
}
