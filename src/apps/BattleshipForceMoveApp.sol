// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ZkForceMoveApp} from './ZkForceMoveApp.sol';
import {VerifyingKey} from 'armada/privacy-pool/types/PoolTypes.sol';

/**
 * @dev A channel app for a Battleship move, with public inputs
 *      [prevCommitment, nextCommitment, boardCommitment, target, result, stake].
 *      Extends ZkForceMoveApp and, before the inherited Groth16 check (super),
 *      requires three invariants on the candidate: the stake (public input 5) equals
 *      proof[0]'s stake else revert 'BattleshipForceMoveApp: stake changed'; the
 *      boardCommitment (public input 2) equals proof[0]'s boardCommitment else revert
 *      'BattleshipForceMoveApp: board changed'; the candidate's prevCommitment
 *      (public input 0) must equal proof[0]'s nextCommitment (public input 1) else
 *      revert 'BattleshipForceMoveApp: commitment chain broken'. The committed
 *      fixtures hit.json/miss.json form a chained pair, so a two-move chain is
 *      supported.
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

        // The candidate's stake (public input 5) must equal proof[0]'s stake.
        require(cand.publicInputs[5] == prior.publicInputs[5], 'BattleshipForceMoveApp: stake changed');

        // The candidate's boardCommitment (public input 2) must equal proof[0]'s boardCommitment.
        require(cand.publicInputs[2] == prior.publicInputs[2], 'BattleshipForceMoveApp: board changed');

        // The candidate's prevCommitment must chain from proof[0]'s nextCommitment.
        require(
            cand.publicInputs[0] == prior.publicInputs[1],
            'BattleshipForceMoveApp: commitment chain broken'
        );

        return super.stateIsSupported(fixedPart, proof, candidate);
    }
}
