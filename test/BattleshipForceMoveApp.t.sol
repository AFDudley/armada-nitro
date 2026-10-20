// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test} from 'forge-std/Test.sol';
import {BattleshipForceMoveApp} from '../src/apps/BattleshipForceMoveApp.sol';
import {ZkForceMoveApp} from '../src/apps/ZkForceMoveApp.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {ChannelStates} from './helpers/ChannelStates.sol';
import {BattleshipAppFixture} from './helpers/BattleshipAppFixture.sol';
import {SnarkProof} from 'armada/privacy-pool/types/PoolTypes.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';

/**
 * @notice N6: BattleshipForceMoveApp, a channel app for a Battleship move with public
 * inputs [prevCommitment, nextCommitment, boardCommitment, target, result, stake].
 * The app extends ZkForceMoveApp and, before the inherited Groth16 check, requires the
 * candidate's stake, board commitment, and commitment chain to match proof[0]. The
 * committed fixtures hit.json (prior move, a hit) and miss.json (the next move, a miss)
 * form a chained pair: miss.prevCommitment == hit.nextCommitment, same board commitment,
 * same stake.
 *
 * The channel is a plain two-party channel (user is participants[0], custodian is
 * participants[1]). `proof[0]` is the prior state (turn 0, user mover, carrying the
 * hit move); the `candidate` is the new state (turn 1, custodian mover, carrying the
 * miss move). `RecoveredVariablePart.signedBy` is a claimed-signer bitmask (already
 * verified upstream by ForceMove's signature recovery); the app only checks the bitmask
 * via StrictTurnTaking, so the tests set it directly.
 */
contract BattleshipForceMoveAppTest is Test, INitroTypes {
    BattleshipForceMoveApp internal app;
    address internal user = address(0x100);
    address internal custodian = address(0x200);

    function setUp() public {
        app = new BattleshipForceMoveApp(BattleshipAppFixture.loadVerifyingKey());
    }

    /// @dev The app builds on ZkForceMoveApp: cast it to the base reference and call the
    ///      inherited Groth16 path. With the valid two-move chain (hit as proof[0], miss
    ///      as candidate) the move is supported with an empty reason.
    function test_extendsZkForceMoveApp() public view {
        ZkForceMoveApp zk = app;

        INitroTypes.FixedPart memory fp = _fixedPart();
        (SnarkProof memory p1, uint256[] memory in1) = BattleshipAppFixture.loadMove('hit.json');
        (SnarkProof memory p2, uint256[] memory in2) = BattleshipAppFixture.loadMove('miss.json');

        INitroTypes.RecoveredVariablePart[] memory proof = _priorState(p1, in1);
        INitroTypes.RecoveredVariablePart memory candidate = _candidate(p2, in2);

        (bool supported, string memory message) = zk.stateIsSupported(fp, proof, candidate);
        assertTrue(supported, 'a valid move via the base class should be supported');
        assertEq(message, '', 'message should be empty for a supported state');
    }

    /// @dev A move whose candidate stake differs from proof[0]'s stake reverts with
    ///      'BattleshipForceMoveApp: stake changed' before the Groth16 check.
    function test_revertsWhenStakeChanged() public {
        INitroTypes.FixedPart memory fp = _fixedPart();
        (SnarkProof memory p1, uint256[] memory in1) = BattleshipAppFixture.loadMove('hit.json');
        (SnarkProof memory p2, uint256[] memory in2) = BattleshipAppFixture.loadMove('miss.json');

        in2[5] = in2[5] ^ 1; // flip one bit of the candidate's stake (public input 5)

        INitroTypes.RecoveredVariablePart[] memory proof = _priorState(p1, in1);
        INitroTypes.RecoveredVariablePart memory candidate = _candidate(p2, in2);

        vm.expectRevert('BattleshipForceMoveApp: stake changed');
        app.stateIsSupported(fp, proof, candidate);
    }

    /// @dev A move whose candidate boardCommitment differs from proof[0]'s boardCommitment
    ///      reverts with 'BattleshipForceMoveApp: board changed' before the Groth16 check.
    function test_revertsWhenBoardChanged() public {
        INitroTypes.FixedPart memory fp = _fixedPart();
        (SnarkProof memory p1, uint256[] memory in2) = BattleshipAppFixture.loadMove('hit.json');
        (SnarkProof memory p2, uint256[] memory in3) = BattleshipAppFixture.loadMove('miss.json');

        in3[2] = in3[2] ^ 1; // flip one bit of the candidate's boardCommitment (public input 2)

        INitroTypes.RecoveredVariablePart[] memory proof = _priorState(p1, in2);
        INitroTypes.RecoveredVariablePart memory candidate = _candidate(p2, in3);

        vm.expectRevert('BattleshipForceMoveApp: board changed');
        app.stateIsSupported(fp, proof, candidate);
    }

    /// @dev A move whose candidate prevCommitment does not match proof[0]'s nextCommitment
    ///      reverts with 'BattleshipForceMoveApp: commitment chain broken' before the
    ///      Groth16 check.
    function test_revertsWhenCommitmentChainBroken() public {
        INitroTypes.FixedPart memory fp = _fixedPart();
        (SnarkProof memory p1, uint256[] memory in1) = BattleshipAppFixture.loadMove('hit.json');
        (SnarkProof memory p2, uint256[] memory in2) = BattleshipAppFixture.loadMove('miss.json');

        in2[0] = in2[0] ^ 1; // flip one bit of the candidate's prevCommitment (public input 0)

        INitroTypes.RecoveredVariablePart[] memory proof = _priorState(p1, in2);
        INitroTypes.RecoveredVariablePart memory candidate = _candidate(p2, in2);

        vm.expectRevert('BattleshipForceMoveApp: commitment chain broken');
        app.stateIsSupported(fp, proof, candidate);
    }

    /// @dev The committed two-move chain (hit as proof[0], miss as candidate) is supported
    ///      with an empty reason.
    function test_twoMoveChainSupported() public view {
        INitroTypes.FixedPart memory fp = _fixedPart();
        (SnarkProof memory p1, uint256[] memory in1) = BattleshipAppFixture.loadMove('hit.json');
        (SnarkProof memory p2, uint256[] memory in2) = BattleshipAppFixture.loadMove('miss.json');

        INitroTypes.RecoveredVariablePart[] memory proof = _priorState(p1, in1);
        INitroTypes.RecoveredVariablePart memory candidate = _candidate(p2, in2);

        (bool supported, string memory message) = app.stateIsSupported(fp, proof, candidate);
        assertTrue(supported, 'a chained valid move should be supported');
        assertEq(message, '', 'message should be empty for a supported state');
    }

    // ------------------ helpers ------------------

    function _fixedPart() internal view returns (INitroTypes.FixedPart memory) {
        return ChannelStates.fixedPart(user, custodian, 1, address(app), 10);
    }

    /// @dev proof[0]: turn 0, claimed signed by the user (participants[0]), carrying the
    ///      prior move's proof and public inputs.
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

    /// @dev candidate: turn 1, claimed signed by the custodian (participants[1]), carrying
    ///      the new move's proof and public inputs in its `appData`.
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
            signedBy: 2
        });
    }
}
