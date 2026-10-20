// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {CommitmentPreimage, ShieldCiphertext, ShieldRequest, Transaction} from 'src/armada/IArmadaPool.sol';
import {IArmadaPool} from 'src/armada/IArmadaPool.sol';

/// @dev A mutable mock of the Armada pool. Its `preimageOf` maps a commitment to a stored
/// `CommitmentPreimage` (the test sets it and can change it, so `heldValue` follows live).
/// `transact` credits the caller (the adjudicator) with the note's value, so `depositFromNote`'s
/// balance delta matches the note value.
contract MockPool is IArmadaPool {
    mapping(bytes32 => CommitmentPreimage) public preimages;

    function setPreimage(bytes32 commitment, CommitmentPreimage memory preimage) external {
        preimages[commitment] = preimage;
    }

    function preimageOf(bytes32 commitment) external view returns (CommitmentPreimage memory) {
        return preimages[commitment];
    }

    /// @dev Registers the shielded note's preimage under its commitment.
    function shield(ShieldRequest[] calldata requests, address) external {
        for (uint256 i = 0; i < requests.length; i++) {
            bytes32 commitment = bytes32(uint256(keccak256(abi.encode(requests[i].preimage))));
            preimages[commitment] = requests[i].preimage;
        }
    }

    /// @dev Credits the caller with the unshielded note's value (the pool holds the token).
    function transact(Transaction[] calldata transactions) external {
        for (uint256 i = 0; i < transactions.length; i++) {
            CommitmentPreimage memory note = transactions[i].unshieldPreimage;
            IERC20(note.token.tokenAddress).transferFrom(address(this), msg.sender, uint256(note.value));
        }
    }

    function transactOwned(Transaction[] calldata transactions) external {}
}
