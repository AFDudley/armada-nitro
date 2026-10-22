// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ZkForceMoveApp} from './ZkForceMoveApp.sol';
import {VerifyingKey} from 'armada/privacy-pool/types/PoolTypes.sol';

/**
 * @dev A Battleship channel app: a move proven by the N6 Battleship circuit (public inputs
 *      [prevCommitment, nextCommitment, boardCommitment, target, result, stake]). It extends
 *      `ZkForceMoveApp` and adds three pre-checks that run before the inherited Groth16 check
 *      (super.stateIsSupported): the candidate's stake (public input 5) must equal the prior
 *      move's stake, the candidate's board commitment (public input 2) must equal the prior
 *      move's board commitment, and the candidate's prevCommitment (public input 0) must equal
 *      the prior move's nextCommitment (public input 1) — so a party cannot finalize on a
 *      valid-looking move that does not chain from the actual prior state. The Groth16 check
 *      itself is `ZkForceMoveApp.stateIsSupported` (reused, not a second verifier).
 */
contract BattleshipForceMoveApp is ZkForceMoveApp {
    constructor(VerifyingKey memory vk) ZkForceMoveApp(vk) {}

    function stateIsSupported(
        FixedPart calldata fixedPart,
        RecoveredVariablePart[] calldata proof,
        RecoveredVariablePart calldata candidate
    ) public view override returns (bool, string memory) {
        require(proof.length == 1, 'proof.length != 1');

        ZkForceMoveApp.AppData memory prior = appData(proof[0].variablePart.appData);
        ZkForceMoveApp.AppData memory cand = appData(candidate.variablePart.appData);

        // The candidate's stake (public input 5) must equal the prior move's stake.
        require(
            cand.publicInputs[5] == prior.publicInputs[5],
            'BattleshipForceMoveApp: stake changed'
        );

        // The candidate's board commitment (public input 2) must equal the prior move's board
        // commitment.
        require(
            cand.publicInputs[2] == prior.publicInputs[2],
            'BattleshipForceMoveApp: board changed'
        );

        // The candidate's prevCommitment (public input 0) must chain from the prior state's
        // nextCommitment (public input 1).
        require(
            cand.publicInputs[0] == prior.publicInputs[1],
            'BattleshipForceMoveApp: commitment chain broken'
        );

        return super.stateIsSupported(fixedPart, proof, candidate);
    }
}
