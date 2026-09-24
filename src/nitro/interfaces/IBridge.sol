// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IBridge {
    // Method to update mirrored ledger channel state
    function updateMirroredChannelStates(
        bytes32 channelId,
        bytes32 stateHash,
        bytes memory outcomeBytes,
        uint256 amount,
        address asset
    ) external;

    event StatusUpdated(bytes32 indexed channelId, bytes32 stateHash);
}
