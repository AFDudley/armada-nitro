// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ZkForceMoveApp} from './ZkForceMoveApp.sol';
import {VerifyingKey} from 'armada/privacy-pool/types/PoolTypes.sol';

/**
 * @dev A Ledger channel app: a hidden-balance move proven by the N5 Ledger circuit
 *      (public inputs [prevCommitment, nextCommitment]). It extends `ZkForceMoveApp`
 *      with a commitment-chain check: the candidate's `prevCommitment` (public input 0)
 *      must equal the prior state's `nextCommitment` (public input 1), so a party cannot
 *      finalize on a valid-looking move that does not chain from the actual prior state.
 *      The Groth16 check itself is `ZkForceMoveApp.stateIsSupported` (reused, not a second
 *      verifier).
 */
contract LedgerForceMoveApp is ZkForceMoveApp {
    constructor(VerifyingKey memory vk) ZkForceMoveApp(vk) {}

    function stateIsSupported(
        FixedPart calldata fixedPart,
        RecoveredVariablePart[] calldata proof,
        RecoveredVariablePart calldata candidate
    ) public view override returns (bool, string memory) {
        require(proof.length == 1, 'proof.length != 1');

        AppData memory prior = appData(proof[0].variablePart.appData);
        AppData memory cand = appData(candidate.variablePart.appData);

        // The candidate's prevCommitment must chain from the prior state's nextCommitment.
        require(
            cand.publicInputs[0] == prior.publicInputs[1],
            'LedgerForceMoveApp: commitment chain broken'
        );

        return super.stateIsSupported(fixedPart, proof, candidate);
    }
}
