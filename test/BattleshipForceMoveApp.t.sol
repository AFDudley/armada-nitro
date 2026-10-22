// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test} from 'forge-std/Test.sol';
import {BattleshipForceMoveApp} from '../src/apps/BattleshipForceMoveApp.sol';
import {ZkForceMoveApp} from '../src/apps/ZkForceMoveApp.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';
import {SnarkProof, VerifyingKey} from 'armada/privacy-pool/types/PoolTypes.sol';
import {BattleshipAppFixture} from './helpers/BattleshipAppFixture.sol';
import {ChannelStates} from './helpers/ChannelStates.sol';

/**
 * @notice N6: BattleshipForceMoveApp, a Battleship channel move. The Battleship circuit proves a
 *      move with public inputs [prevCommitment, nextCommitment, boardCommitment, target, result,
 *      stake]. The app reuses ZkForceMoveApp's Groth16 check and adds three pre-checks that run
 *      before it: the candidate's stake (public input 5) and board commitment (public input 2) must
 *      match the prior move, and the candidate's prevCommitment (public input 0) must equal the
 *      prior move's nextCommitment (public input 1). The committed fixtures hit.json and miss.json
 *      are a chained pair (hit's nextCommitment == miss's prevCommitment).
 *
 * The channel is a plain two-party channel (user is participants[0], custodian is
 * participants[1]). proof[0] is the prior state (turn 0, user mover); candidate is the new state
 * (turn 1, custodian mover). `RecoveredVariablePart.signedBy` is a claimed-signer bitmask the app
 * checks via StrictTurnTaking, so the tests set it directly without real ECDSA signatures.
 */
contract BattleshipForceMoveAppTest is Test, INitroTypes {
    BattleshipForceMoveApp internal app;
    address internal user = address(0x100);
    address internal custodian = address(0x200);

    function setUp() public {
        app = new BattleshipForceMoveApp(BattleshipAppFixture.loadVerifyingKey());
    }

    /// @dev The app IS-A ZkForceMoveApp (assignable to the base reference type), and its own
    ///      stateIsSupported answers for a valid move: a chained pair (hit -> miss) is supported
    ///      with an empty reason.
    function test_extendsZkForceMoveApp() public view {
        ZkForceMoveApp base = app;

        INitroTypes.FixedPart memory fp = _fixedPart();
        (SnarkProof memory p1, uint256[] memory in1) = BattleshipAppFixture.loadMove('hit.json');
        (SnarkProof memory p2, uint256[] memory in2) = BattleshipAppFixture.loadMove('miss.json');

        INitroTypes.RecoveredVariablePart[] memory proof = _priorState(p1, in1);
        INitroTypes.RecoveredVariablePart memory candidate = _candidate(p2, in2);

        (bool supported, string memory message) = app.stateIsSupported(fp, proof, candidate);
        assertTrue(supported, 'valid move should be supported');
        assertEq(message, '', 'message should be empty for a supported state');

        (bool baseSupported, string memory baseMessage) = base.stateIsSupported(fp, proof, candidate);
        assertTrue(baseSupported, 'base reference should see the same supported state');
        assertEq(baseMessage, '', 'base reference message should be empty');
    }

    /// @dev When the candidate's stake (public input 5) is changed by one bit it is refused before
    ///      the Groth16 check.
    function test_revertsWhenStakeChanged() public {
        INitroTypes.FixedPart memory fp = _fixedPart();
        (SnarkProof memory p1, uint256[] memory in1) = BattleshipAppFixture.loadMove('hit.json');
        (SnarkProof memory p2, uint256[] memory in2) = BattleshipAppFixture.loadMove('miss.json');

        in2[5] = in2[5] ^ 1; // flip one bit of the candidate's stake

        INitroTypes.RecoveredVariablePart[] memory proof = _priorState(p1, in1);
        INitroTypes.RecoveredVariablePart memory candidate = _candidate(p2, in2);

        vm.expectRevert('BattleshipForceMoveApp: stake changed');
        app.stateIsSupported(fp, proof, candidate);
    }

    /// @dev When the candidate's board commitment (public input 2) is changed by one bit it is
    ///      refused before the Groth16 check.
    function test_revertsWhenBoardChanged() public {
        INitroTypes.FixedPart memory fp = _fixedPart();
        (SnarkProof memory p1, uint256[] memory in1) = BattleshipAppFixture.loadMove('hit.json');
        (SnarkProof memory p2, uint256[] memory in2) = BattleshipAppFixture.loadMove('miss.json');

        in2[2] = in2[2] ^ 1; // flip one bit of the candidate's board commitment

        INitroTypes.RecoveredVariablePart memory candidate = _candidate(p2, in2);
        INitroTypes.RecoveredVariablePart[] memory proof = _priorState(p1, in1);

        vm.expectRevert('BattleshipForceMoveApp: board changed');
        app.stateIsSupported(fp, proof, candidate);
    }

    /// @dev When the prior state's nextCommitment is changed by one bit it no longer chains to the
    ///      candidate's prevCommitment; the app reverts before the Groth16 check.
    function test_revertsWhenCommitmentChainBroken() public {
        INitroTypes.FixedPart memory fp = _fixedPart();
        (SnarkProof memory p1, uint256[] memory in1) = BattleshipAppFixture.loadMove('hit.json');
        (SnarkProof memory p2, uint256[] memory in2) = BattleshipAppFixture.loadMove('miss.json');

        in1[1] = in1[1] ^ 1; // flip one bit of the prior state's nextCommitment

        INitroTypes.RecoveredVariablePart[] memory proof = _priorState(p1, in1);
        INitroTypes.RecoveredVariablePart memory candidate = _candidate(p2, in2);

        vm.expectRevert('BattleshipForceMoveApp: commitment chain broken');
        app.stateIsSupported(fp, proof, candidate);
    }

    /// @dev The committed hit and miss fixtures are a chained pair: the hit move's nextCommitment
    ///      equals the miss move's prevCommitment, and the app reports the miss move as supported
    ///      with an empty reason.
    function test_twoMoveChainSupported() public view {
        INitroTypes.FixedPart memory fp = _fixedPart();
        (SnarkProof memory p1, uint256[] memory in1) = BattleshipAppFixture.loadMove('hit.json');
        (SnarkProof memory p2, uint256[] memory in2) = BattleshipAppFixture.loadMove('miss.json');

        INitroTypes.RecoveredVariablePart[] memory proof = _priorState(p1, in1);
        INitroTypes.RecoveredVariablePart memory candidate = _candidate(p2, in2);

        (bool supported, string memory message) = app.stateIsSupported(fp, proof, candidate);
        assertTrue(supported, 'chained valid move should be supported');
        assertEq(message, '', 'message should be empty for a supported state');
    }

    // ------------------ helpers ------------------

    function _fixedPart() internal view returns (INitroTypes.FixedPart memory) {
        return ChannelStates.fixedPart(user, custodian, 1, address(app), 10);
    }

    /// @dev proof[0]: turn 0, claimed signed by the user (participants[0]), carrying the prior
    ///      move's proof and its public inputs.
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

    /// @dev candidate: turn 1, claimed signed by the custodian (participants[1]), carrying the new
    ///      move's proof and public inputs.
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
