// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {IForceMoveApp} from '../nitro/interfaces/IForceMoveApp.sol';
import {StrictTurnTaking} from '../nitro/libraries/signature-logic/StrictTurnTaking.sol';
import {SnarkProof, VerifyingKey} from 'armada/privacy-pool/types/PoolTypes.sol';
import {Snark} from 'armada/privacy-pool/types/SnarkTypes.sol';

/**
 * @dev A generic channel app whose state is supported only when the state carries a
 *      Groth16 proof that verifies against the pool's existing Snark library, with a
 *      verifying key fixed at deployment. No pairing code of its own.
 */
contract ZkForceMoveApp is IForceMoveApp {
    struct AppData {
        SnarkProof proof;
        uint256[] publicInputs;
    }

    /// @dev Set once at deployment. `VerifyingKey` holds a dynamic array (`ic`), so it cannot
    ///      be `immutable`; it is stored in storage with a set-once intent (no setter).
    VerifyingKey verifyingKey_;

    constructor(VerifyingKey memory vk) {
        // solc 0.8.17 cannot copy a struct holding a dynamic array of structs (`ic`) from
        // memory to storage in one assignment; copy field by field instead.
        verifyingKey_.alpha1 = vk.alpha1;
        verifyingKey_.beta2 = vk.beta2;
        verifyingKey_.gamma2 = vk.gamma2;
        verifyingKey_.delta2 = vk.delta2;
        for (uint256 i = 0; i < vk.ic.length; i++) {
            verifyingKey_.ic.push(vk.ic[i]);
        }
    }

    /// @notice The verifying key fixed at deployment, for tests.
    function verifyingKey() external view returns (VerifyingKey memory) {
        return verifyingKey_;
    }

    /// @notice Decodes the appData.
    /// @dev Decodes the appData, the same pattern `HashLockedSwap.appData` uses.
    function appData(bytes memory appDataBytes) internal pure returns (AppData memory) {
        return abi.decode(appDataBytes, (AppData));
    }

    /// @notice Accepts a candidate state only when it carries a Groth16 proof that verifies
    ///         against the fixed verifying key, over public inputs bound to the state.
    /// @param fixedPart Fixed part of the state channel.
    /// @param proof Array of recovered variable parts which constitutes a support proof for
    ///        the candidate. Must hold exactly one prior state.
    /// @param candidate Recovered variable part the proof was supplied for; its `appData`
    ///        carries the Groth16 proof and its public inputs.
    function stateIsSupported(
        FixedPart calldata fixedPart,
        RecoveredVariablePart[] calldata proof,
        RecoveredVariablePart calldata candidate
    ) external view override returns (bool, string memory) {
        require(proof.length == 1, 'proof.length != 1');

        StrictTurnTaking.requireValidTurnTaking(fixedPart, proof, candidate);

        AppData memory data = appData(candidate.variablePart.appData);

        // Snark.verify reverts on a structurally invalid proof (e.g. an off-curve point); that
        // revert is not caught here, and propagates to the caller.
        bool supported = Snark.verify(verifyingKey_, data.proof, data.publicInputs);
        if (supported) {
            return (true, '');
        } else {
            return (false, 'ZkForceMoveApp: invalid proof');
        }
    }
}
