// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test} from 'forge-std/Test.sol';
import {LedgerForceMoveApp} from '../src/apps/LedgerForceMoveApp.sol';
import {ZkForceMoveApp} from '../src/apps/ZkForceMoveApp.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {ChannelStates} from './helpers/ChannelStates.sol';
import {LedgerAppFixture} from './helpers/LedgerAppFixture.sol';
import {SnarkProof} from 'armada/privacy-pool/types/PoolTypes.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';

/**
 * @notice N5: LedgerForceMoveApp, a hidden-balance channel move. The Ledger circuit proves a
 * conserved move with public inputs [prevCommitment, nextCommitment]. The app reuses
 * ZkForceMoveApp's Groth16 check and adds a commitment-chain check: the candidate's
 * prevCommitment must equal the prior state's nextCommitment. move1.json/move2.json are two
 * chained moves (move2's prevCommitment == move1's nextCommitment) from the real circuit.
 *
 * The channel is a plain two-party channel (user is participants[0], custodian is
 * participants[1]). proof[0] is the prior state (turn 0, user mover, carrying move1); candidate
 * is the new state (turn 1, custodian mover, carrying move2). signedBy is a claimed-signer
 * bitmask the app checks via StrictTurnTaking, so the tests set it directly.
 */
contract LedgerForceMoveAppTest is Test, INitroTypes {
    LedgerForceMoveApp internal app;
    address internal user = address(0x100);
    address internal custodian = address(0x200);

    function setUp() public {
        app = new LedgerForceMoveApp(LedgerAppFixture.loadVerifyingKey());
    }

    /// @dev A chained move (move2.prevCommitment == move1.nextCommitment) with a valid proof is supported.
    function test_twoMoveChain_supported() public view {
        INitroTypes.FixedPart memory fp = _fixedPart();
        (SnarkProof memory p1, uint256[] memory in1) = LedgerAppFixture.loadMove('move1.json');
        (SnarkProof memory p2, uint256[] memory in2) = LedgerAppFixture.loadMove('move2.json');

        INitroTypes.RecoveredVariablePart[] memory proof = _priorState(p1, in1);
        INitroTypes.RecoveredVariablePart memory candidate = _candidate(p2, in2);

        (bool supported, string memory message) = app.stateIsSupported(fp, proof, candidate);
        assertTrue(supported, 'chained valid move should be supported');
        assertEq(message, '', 'message should be empty for a supported state');
    }

    /// @dev When the prior state's nextCommitment is changed by one bit it no longer chains to
    ///      the candidate's prevCommitment; the app reverts before the Groth16 check.
    function test_brokenChain_reverts() public {
        INitroTypes.FixedPart memory fp = _fixedPart();
        (SnarkProof memory p1, uint256[] memory in1) = LedgerAppFixture.loadMove('move1.json');
        (SnarkProof memory p2, uint256[] memory in2) = LedgerAppFixture.loadMove('move2.json');

        in1[1] = in1[1] ^ 1; // flip one bit of proof[0]'s nextCommitment

        INitroTypes.RecoveredVariablePart[] memory proof = _priorState(p1, in1);
        INitroTypes.RecoveredVariablePart memory candidate = _candidate(p2, in2);

        vm.expectRevert('LedgerForceMoveApp: commitment chain broken');
        app.stateIsSupported(fp, proof, candidate);
    }

    // ------------------ helpers ------------------

    function _fixedPart() internal view returns (INitroTypes.FixedPart memory) {
        return ChannelStates.fixedPart(user, custodian, 1, address(app), 10);
    }

    /// @dev proof[0]: turn 0, claimed signed by the user, carrying the prior move's proof.
    function _priorState(
        SnarkProof memory proof,
        uint256[] memory publicInputs
    ) internal pure returns (INitroTypes.RecoveredVariablePart[] memory) {
        INitroTypes.RecoveredVariablePart[] memory arr = new INitroTypes.RecoveredVariablePart[](1);
        arr[0] = INitroTypes.RecoveredVariablePart({
            variablePart: INitroTypes.VariablePart({
                outcome: new Outcome.SingleAssetExit[](0),
                appData: abi.encode(ZkForceMoveApp.AppData(proof, publicInputs)),
                turnNum: 0,
                isFinal: false
            }),
            signedBy: 1 // bit 0 (participants[0], the user, is the turn-0 mover)
        });
        return arr;
    }

    /// @dev candidate: turn 1, claimed signed by the custodian, carrying the new move's proof.
    function _candidate(
        SnarkProof memory proof,
        uint256[] memory publicInputs
    ) internal pure returns (INitroTypes.RecoveredVariablePart memory) {
        return INitroTypes.RecoveredVariablePart({
            variablePart: INitroTypes.VariablePart({
                outcome: new Outcome.SingleAssetExit[](0),
                appData: abi.encode(ZkForceMoveApp.AppData(proof, publicInputs)),
                turnNum: 1,
                isFinal: false
            }),
            signedBy: 2 // bit 1 (participants[1], the custodian, is the turn-1 mover)
        });
    }
}
