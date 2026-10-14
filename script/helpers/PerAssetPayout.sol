// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Vm} from 'forge-std/Vm.sol';
import {console2} from 'forge-std/console2.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';

/**
 * @dev E16 S4 (design 15, I5): pay out a finalized channel so that one asset whose token reverts
 * on transfer cannot block the payout of the other assets. See
 * docs/tasks/E16-adjudicator-hardening.md.
 *
 * Every payout call is probed first on a `vm.snapshotState()` that is reverted right after, and
 * is broadcast only if the probe succeeds. A reverting low-level call made under an active
 * `vm.broadcast()` still gets queued by forge script, and its replay then fails the whole script
 * with "Simulated execution failed." before any fallback could run.
 */
library PerAssetPayout {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));

    /// @dev Pay `outcome` with one `transferAllAssets` if it succeeds; otherwise pay each asset on
    /// its own with `payEachAsset`.
    function settle(
        ArmadaNitroAdjudicator adjudicator,
        uint256 senderKey,
        bytes32 channelId,
        Outcome.SingleAssetExit[] memory outcome,
        bytes32 stateHash
    ) internal {
        uint256 snap = vm.snapshotState();
        (bool ok, bytes memory ret) = address(adjudicator).call(
            abi.encodeCall(adjudicator.transferAllAssets, (channelId, outcome, stateHash))
        );
        vm.revertToState(snap);

        if (ok) {
            vm.broadcast(senderKey);
            adjudicator.transferAllAssets(channelId, outcome, stateHash);
            console2.log('transferAllAssets succeeded');
            return;
        }
        console2.log('transferAllAssets reverted:', revertReason(ret));
        payEachAsset(adjudicator, senderKey, channelId, outcome, stateHash);
    }

    /// @dev For each asset of `outcome`, broadcast `transfer(assetIndex, ...)` if its probe
    /// succeeds. An asset whose payout reverts gets no transaction, and its holdings stay as they
    /// were. A successful transfer pays every allocation of the asset in full (each channel these
    /// scripts settle holds exactly its outcome's total per asset), so the on-chain fingerprint
    /// then records that asset's allocations as zero. The loop zeroes them in `outcome` too, so
    /// the next asset's call hashes to the current fingerprint.
    function payEachAsset(
        ArmadaNitroAdjudicator adjudicator,
        uint256 senderKey,
        bytes32 channelId,
        Outcome.SingleAssetExit[] memory outcome,
        bytes32 stateHash
    ) internal {
        uint256[] memory allAllocations = new uint256[](0);
        for (uint256 i = 0; i < outcome.length; i++) {
            bytes memory outcomeBytes = abi.encode(outcome);
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = address(adjudicator).call(
                abi.encodeCall(adjudicator.transfer, (i, channelId, outcomeBytes, stateHash, allAllocations))
            );
            vm.revertToState(snap);

            if (!ok) {
                console2.log('asset', i, 'per-asset transfer reverted:', revertReason(ret));
                continue;
            }
            vm.broadcast(senderKey);
            adjudicator.transfer(i, channelId, outcomeBytes, stateHash, allAllocations);
            for (uint256 j = 0; j < outcome[i].allocations.length; j++) {
                outcome[i].allocations[j].amount = 0;
            }
        }
    }

    /// @dev The reason string of an `Error(string)` revert; otherwise the raw revert data in hex.
    function revertReason(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 4) return '<no revert reason>';
        if (bytes4(ret) != bytes4(keccak256('Error(string)'))) return vm.toString(ret);
        bytes memory encoded = new bytes(ret.length - 4);
        for (uint256 i = 0; i < encoded.length; i++) {
            encoded[i] = ret[i + 4];
        }
        return abi.decode(encoded, (string));
    }
}
