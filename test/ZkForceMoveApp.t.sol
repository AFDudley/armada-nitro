// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test} from 'forge-std/Test.sol';
import {ZkForceMoveApp} from '../src/apps/ZkForceMoveApp.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {ChannelStates} from './helpers/ChannelStates.sol';
import {ZkAppFixture} from './helpers/ZkAppFixture.sol';
import {SnarkProof} from 'armada/privacy-pool/types/PoolTypes.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';

/**
 * @notice N4: a channel app accepts a state only when it carries a valid Groth16 proof.
 * The trivial circuit is `y = x * x` (x = 3, y = 9, proven and committed under
 * test/fixtures/zk-app/trivial/). A valid proof is supported; a wrong public input, a
 * mangled proof, and a proof array whose length is not 1 are each refused.
 *
 * The channel is a plain two-party channel (user is participants[0], custodian is
 * participants[1]). `proof[0]` is the prior state (turn 0, user is mover); `candidate`
 * is the new state (turn 1, custodian is mover) whose `appData` carries the ZK proof.
 * `RecoveredVariablePart.signedBy` is a claimed-signer bitmask (already verified upstream
 * by ForceMove's signature recovery); this app only checks the bitmask via
 * `StrictTurnTaking`, so the tests set it directly without real ECDSA signatures.
 */
contract ZkForceMoveAppTest is Test, INitroTypes {
    ZkForceMoveApp internal app;
    address internal user = address(0x100);
    address internal custodian = address(0x200);

    function setUp() public {
        app = new ZkForceMoveApp(ZkAppFixture.loadTrivialVerifyingKey());
    }

    /// @dev A state with a valid proof for the trivial circuit is supported.
    function test_supported_whenValidProof() public view {
        INitroTypes.FixedPart memory fp = _fixedPart();
        INitroTypes.RecoveredVariablePart[] memory proof = _priorStateProof();
        INitroTypes.RecoveredVariablePart memory candidate = _candidate(
            ZkAppFixture.loadTrivialProof(),
            9
        );

        (bool supported, string memory message) = app.stateIsSupported(fp, proof, candidate);
        assertTrue(supported, 'valid proof should be supported');
        assertEq(message, '', 'message should be empty for a supported state');
    }

    /// @dev A state whose proof is valid but whose public input is wrong is refused.
    function test_refused_whenWrongPublicInput() public view {
        INitroTypes.FixedPart memory fp = _fixedPart();
        INitroTypes.RecoveredVariablePart[] memory proof = _priorStateProof();
        INitroTypes.RecoveredVariablePart memory candidate = _candidate(
            ZkAppFixture.loadTrivialProof(),
            10
        );

        (bool supported, string memory message) = app.stateIsSupported(fp, proof, candidate);
        assertFalse(supported, 'wrong public input should be refused');
        assertEq(message, 'ZkForceMoveApp: invalid proof', 'refusal reason');
    }

    /// @dev A structurally mangled proof (one flipped bit of `proof.a.x`) takes the proof
    ///      point off the bn128 curve. `Snark.verify`'s point-validity check -- and the bn128
    ///      EC precompiles underneath it -- reject off-curve points by reverting, not by
    ///      returning false; per the brief, `stateIsSupported` does not catch or swallow that
    ///      revert, so it propagates here too. From the adjudicator's perspective a revert and
    ///      a `(false, ...)` return are the same outcome: the candidate state is not supported.
    function test_refused_whenMangledProof() public {
        INitroTypes.FixedPart memory fp = _fixedPart();
        INitroTypes.RecoveredVariablePart[] memory proof = _priorStateProof();

        SnarkProof memory mangled = ZkAppFixture.loadTrivialProof();
        mangled.a.x = mangled.a.x ^ 1; // flip one bit of proof.a.x

        INitroTypes.RecoveredVariablePart memory candidate = _candidate(mangled, 9);

        vm.expectRevert('Snark: Invalid negation');
        app.stateIsSupported(fp, proof, candidate);
    }

    /// @dev A proof array whose length is not 1 is refused (the `require` in `stateIsSupported`).
    function test_reverts_whenProofLengthNotOne() public {
        INitroTypes.FixedPart memory fp = _fixedPart();
        INitroTypes.RecoveredVariablePart[] memory emptyProof = new INitroTypes.RecoveredVariablePart[](0);
        INitroTypes.RecoveredVariablePart memory candidate = _candidate(
            ZkAppFixture.loadTrivialProof(),
            9
        );

        vm.expectRevert('proof.length != 1');
        app.stateIsSupported(fp, emptyProof, candidate);
    }

    // ------------------ helpers ------------------

    function _fixedPart() internal view returns (INitroTypes.FixedPart memory) {
        return ChannelStates.fixedPart(user, custodian, 1, address(app), 10);
    }

    /// @dev proof[0]: turn 0, claimed signed only by the user (participants[0]).
    function _priorStateProof() internal pure returns (INitroTypes.RecoveredVariablePart[] memory) {
        INitroTypes.RecoveredVariablePart[] memory proof = new INitroTypes.RecoveredVariablePart[](1);
        proof[0] = INitroTypes.RecoveredVariablePart({
            variablePart: INitroTypes.VariablePart({
                outcome: new Outcome.SingleAssetExit[](0),
                appData: '',
                turnNum: 0,
                isFinal: false
            }),
            signedBy: 1 // bit 0 (participants[0], the user, is the turn-0 mover)
        });
        return proof;
    }

    /// @dev candidate: turn 1, claimed signed only by the custodian (participants[1]), carrying
    ///      the given ZK proof and public input in its `appData`.
    function _candidate(
        SnarkProof memory proof,
        uint256 publicInput
    ) internal pure returns (INitroTypes.RecoveredVariablePart memory) {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = publicInput;

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
