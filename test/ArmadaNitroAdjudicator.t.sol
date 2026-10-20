// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Vm} from 'forge-std/Test.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {ConsensusApp} from 'src/nitro/ConsensusApp.sol';
import {NitroUtils} from 'src/nitro/libraries/NitroUtils.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {IForceMoveApp} from 'src/nitro/interfaces/IForceMoveApp.sol';
import {
    IArmadaPool,
    BoundParams,
    CommitmentPreimage,
    G1Point,
    G2Point,
    ShieldCiphertext,
    ShieldRequest,
    SnarkProof,
    TokenData,
    TokenType,
    Transaction,
    UnshieldType
} from 'src/armada/IArmadaPool.sol';
import {ArmadaFixture} from './helpers/ArmadaFixture.sol';
import {ArmadaNotes} from './helpers/ArmadaNotes.sol';
import {ChannelStates} from './helpers/ChannelStates.sol';
import {IHubCustodian, IFrostTestSigner} from './helpers/IHubCustodian.sol';

/// @dev Accepts every state, so a test can isolate signature recovery from app rules.
contract AlwaysSupportedApp is IForceMoveApp {
    function stateIsSupported(
        FixedPart calldata,
        RecoveredVariablePart[] calldata,
        RecoveredVariablePart calldata
    ) external pure override returns (bool, string memory) {
        return (true, '');
    }
}

/// @dev A hostile channel participant: its EIP-1271 check never returns.
contract GasBombParticipant {
    function isValidSignature(bytes32, bytes memory) external view returns (bytes4) {
        while (gasleft() > 0) {}
        return 0x1626ba7e;
    }
}

/// @dev N2a: a test pool whose `transact` is a no-op (no ERC-20 leaves the pool), while its
/// settable `preimageOf` registry lets a test register a commitment's preimage (value, owner) to
/// exercise the adjudicator's value and owner checks.
contract N2aPool is IArmadaPool {
    mapping(bytes32 => CommitmentPreimage) public preimages;

    function setPreimage(bytes32 commitment, CommitmentPreimage memory preimage) external {
        preimages[commitment] = preimage;
    }

    function shield(ShieldRequest[] calldata requests, address) external {}

    function transact(Transaction[] calldata) external {}

    function preimageOf(bytes32 commitment) external view returns (CommitmentPreimage memory) {
        return preimages[commitment];
    }

    function transactOwned(Transaction[] calldata) external {}
}

/// @dev Test harness that exposes a setter for `holdingsLock` so the reentrancy guard can be
/// driven from a test (the guard reverts before it reaches the pool).
contract AdjudicatorHarness is ArmadaNitroAdjudicator {
    constructor(
        IArmadaPool pool_,
        address[] memory assets_
    ) ArmadaNitroAdjudicator(pool_, assets_) {}

    function setHoldingsLock(bytes32 channelId, uint256 value) external {
        holdingsLock[channelId] = value;
    }
}

contract ArmadaNitroAdjudicatorTest is ArmadaFixture, INitroTypes {
    uint256 internal constant USER_KEY = 0xA11CE;
    uint256 internal constant DELEGATE_KEY = 0xDE1E6A7E;
    uint256 internal constant GROUP_SCALAR =
        0xA4DDF31F7F32BA696F14CE50ECF3F21E3E100E83BDF47966E7B07468E9500B6E;
    uint48 internal constant CHALLENGE_DURATION = 1 days;
    uint256 internal constant REVOCATION_DELAY = 3 days;
    uint120 internal constant USER_FUNDS = 100e6;
    uint120 internal constant HUB_FUNDS = 100e6;

    bytes32 internal constant USER_DEPOSIT_NPK = bytes32(uint256(0x1111));
    bytes32 internal constant USER_PAYOUT_NPK = bytes32(uint256(0x2222));

    ArmadaNitroAdjudicator internal adjudicator;
    ConsensusApp internal consensusApp;
    IHubCustodian internal custodian;
    IFrostTestSigner internal frost;
    address internal user;
    address internal delegate;
    address internal broadcaster = address(0xB0CA);

    function setUp() public {
        _deployArmada();
        address[] memory assets = new address[](4);
        assets[0] = address(usdc);
        assets[1] = address(0x0000000000000000000000000000000000000001); // WETH
        assets[2] = address(0x0000000000000000000000000000000000000002); // wstETH
        assets[3] = address(0x0000000000000000000000000000000000000003); // waUSDC
        adjudicator = new ArmadaNitroAdjudicator(pool, assets);

        consensusApp = new ConsensusApp();
        user = vm.addr(USER_KEY);
        delegate = vm.addr(DELEGATE_KEY);

        frost = IFrostTestSigner(deployCode('FrostTestSigner.sol:FrostTestSigner'));
        (uint256 x, uint256 y) = frost.publicKey(GROUP_SCALAR);
        custodian = IHubCustodian(
            deployCode('HubCustodian.sol:HubCustodian', abi.encode(x, y, REVOCATION_DELAY))
        );
        _hubExecute(address(custodian), abi.encodeCall(IHubCustodian.authorizeDelegate, (delegate)));
    }

    // ---------------------------------------------------------------- funding

    function test_depositFromNote_creditsChannelFromShieldedNote() public {
        N2aPool n2aPool = new N2aPool();
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        ArmadaNitroAdjudicator n2aAdjudicator = new ArmadaNitroAdjudicator(
            IArmadaPool(address(n2aPool)), assets
        );
        bytes32 channelId = _channelId(_fixedPart(address(consensusApp)));
        _shield(user, USER_DEPOSIT_NPK, USER_FUNDS);
        Transaction[] memory txs = _unshield(
            address(n2aAdjudicator),
            USER_FUNDS,
            address(n2aAdjudicator),
            n2aAdjudicator.depositBinding(channelId, 0),
            0
        );
        n2aPool.setPreimage(
            txs[0].commitments[0],
            ArmadaNotes.usdcNote(address(usdc), bytes32(uint256(uint160(address(n2aAdjudicator)))), USER_FUNDS)
        );
        vm.prank(broadcaster);
        n2aAdjudicator.depositFromNote(channelId, 0, txs);
        assertEq(n2aAdjudicator.heldValue(address(usdc), channelId), USER_FUNDS);
        assertEq(usdc.balanceOf(address(n2aAdjudicator)), 0);
    }

    function test_depositFromNote_rejectsUnshieldBoundToAnotherChannel() public {
        bytes32 channelId = _channelId(_fixedPart(address(consensusApp)));
        bytes32 otherChannelId = keccak256('other channel');
        _shield(user, USER_DEPOSIT_NPK, USER_FUNDS);
        Transaction[] memory txs = _unshield(
            address(adjudicator),
            USER_FUNDS,
            address(adjudicator),
            adjudicator.depositBinding(channelId, 0),
            0
        );

        vm.prank(broadcaster);
        vm.expectRevert('Wrong adaptParams');
        adjudicator.depositFromNote(otherChannelId, 0, txs);
    }

    function test_depositFromNote_rejectsStaleExpectedHeld() public {
        bytes32 channelId = _channelId(_fixedPart(address(consensusApp)));
        _shield(user, USER_DEPOSIT_NPK, 2 * USER_FUNDS);
        _depositFromNote(channelId, 0, USER_FUNDS);

        // A second unshield signed against the pre-deposit holding cannot land on top of the first.
        Transaction[] memory txs = _unshield(
            address(adjudicator),
            USER_FUNDS,
            address(adjudicator),
            adjudicator.depositBinding(channelId, 0),
            0
        );
        vm.prank(broadcaster);
        vm.expectRevert('held != expectedHeld');
        adjudicator.depositFromNote(channelId, 0, txs);
    }

    function test_boundUnshield_cannotBeSubmittedAroundTheAdjudicator() public {
        bytes32 channelId = _channelId(_fixedPart(address(consensusApp)));
        _shield(user, USER_DEPOSIT_NPK, USER_FUNDS);
        Transaction[] memory txs = _unshield(
            address(adjudicator),
            USER_FUNDS,
            address(adjudicator),
            adjudicator.depositBinding(channelId, 0),
            0
        );

        vm.prank(broadcaster);
        vm.expectRevert('TransactModule: Invalid Adapt Contract');
        pool.transact(txs);
    }

    // ---------------------------------------------------------------- N2a acceptance (spec derived-arn-61e)

    function test_depositFromNote_creditsHoldingsToNewCommitment() public {
        bytes32 channelId = _channelId(_fixedPart(address(consensusApp)));
        _shield(user, USER_DEPOSIT_NPK, USER_FUNDS);
        _depositFromNote(channelId, 0, USER_FUNDS);

        // N2a: the channel's holding is the pool's new commitment (a bytes32 reference), not a
        // raw balance; the held amount reads back as the deposited amount.
        bytes32 holding = adjudicator.holdings(address(usdc), channelId);
        assertTrue(holding != bytes32(0), 'no new commitment recorded');
        assertEq(adjudicator.heldValue(address(usdc), channelId), USER_FUNDS);
    }

    function test_depositFromNote_revertsOnValueMismatch() public {
        N2aPool n2aPool = new N2aPool();
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        ArmadaNitroAdjudicator n2aAdjudicator = new ArmadaNitroAdjudicator(
            IArmadaPool(address(n2aPool)), assets
        );
        bytes32 channelId = _channelId(_fixedPart(address(consensusApp)));
        Transaction[] memory txs = _unshield(
            address(n2aAdjudicator),
            USER_FUNDS,
            address(n2aAdjudicator),
            n2aAdjudicator.depositBinding(channelId, 0),
            0
        );
        // Register the pool's preimage with a value different from the expected amount (USER_FUNDS),
        // so the adjudicator's value check reverts.
        n2aPool.setPreimage(
            txs[0].commitments[0],
            ArmadaNotes.usdcNote(address(usdc), bytes32(uint256(uint160(address(n2aAdjudicator)))), 1)
        );
        vm.prank(broadcaster);
        vm.expectRevert('Collateral value mismatch');
        n2aAdjudicator.depositFromNote(channelId, 0, txs);
    }

    function test_depositFromNote_revertsOnWrongOwner() public {
        N2aPool n2aPool = new N2aPool();
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        ArmadaNitroAdjudicator n2aAdjudicator = new ArmadaNitroAdjudicator(
            IArmadaPool(address(n2aPool)), assets
        );
        bytes32 channelId = _channelId(_fixedPart(address(consensusApp)));
        Transaction[] memory txs = _unshield(
            address(n2aAdjudicator),
            USER_FUNDS,
            address(n2aAdjudicator),
            n2aAdjudicator.depositBinding(channelId, 0),
            0
        );
        // Register the pool's preimage with a wrong npk (not the adjudicator's derived owner).
        n2aPool.setPreimage(
            txs[0].commitments[0],
            ArmadaNotes.usdcNote(address(usdc), bytes32(uint256(uint160(address(0x1234)))), USER_FUNDS)
        );
        vm.prank(broadcaster);
        vm.expectRevert('Collateral not adjudicator-owned');
        n2aAdjudicator.depositFromNote(channelId, 0, txs);
    }

    function test_depositFromNote_noRawTokenBalanceChange() public {
        N2aPool n2aPool = new N2aPool();
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        ArmadaNitroAdjudicator n2aAdjudicator = new ArmadaNitroAdjudicator(
            IArmadaPool(address(n2aPool)), assets
        );
        bytes32 channelId = _channelId(_fixedPart(address(consensusApp)));
        Transaction[] memory txs = _unshield(
            address(n2aAdjudicator),
            USER_FUNDS,
            address(n2aAdjudicator),
            n2aAdjudicator.depositBinding(channelId, 0),
            0
        );
        // N2a: the deposit moves value into a contract-owned note inside the pool; no ERC-20 leaves
        // the pool, so the adjudicator's raw token balance is unchanged.
        n2aPool.setPreimage(
            txs[0].commitments[0],
            ArmadaNotes.usdcNote(address(usdc), bytes32(uint256(uint160(address(n2aAdjudicator)))), USER_FUNDS)
        );
        uint256 balanceBefore = usdc.balanceOf(address(n2aAdjudicator));
        vm.prank(broadcaster);
        n2aAdjudicator.depositFromNote(channelId, 0, txs);
        assertEq(usdc.balanceOf(address(n2aAdjudicator)), balanceBefore);
    }

    function test_depositFromNote_guardsReentrancyAndExpectedHeld() public {
        // (a) Re-entrant deposit is rejected: a nested call on this channel reverts before the pool.
        address[] memory harnessAssets = new address[](1);
        harnessAssets[0] = address(usdc);
        AdjudicatorHarness harness = new AdjudicatorHarness(pool, harnessAssets);
        bytes32 channelId = _channelId(_fixedPart(address(consensusApp)));
        harness.setHoldingsLock(channelId, 1);
        Transaction[] memory txs = _unshield(
            address(harness),
            USER_FUNDS,
            address(harness),
            harness.depositBinding(channelId, 0),
            0
        );
        vm.prank(broadcaster);
        vm.expectRevert('Re-entered while in progress');
        harness.depositFromNote(channelId, 0, txs);

        // (b) A deposit with a wrong expected holding amount is rejected.
        _shield(user, USER_DEPOSIT_NPK, 2 * USER_FUNDS);
        _depositFromNote(channelId, 0, USER_FUNDS);
        Transaction[] memory staleTxs = _unshield(
            address(adjudicator),
            USER_FUNDS,
            address(adjudicator),
            adjudicator.depositBinding(channelId, 0),
            0
        );
        vm.prank(broadcaster);
        vm.expectRevert('held != expectedHeld');
        adjudicator.depositFromNote(channelId, 0, staleTxs);
    }

    // ---------------------------------------------------------------- settlement

    function test_cooperativeClose_shieldsUserNoteAndPaysCustodian() public {
        FixedPart memory fixedPart = _fixedPart(address(consensusApp));
        _fundChannel(_channelId(fixedPart));
        VariablePart memory finalState = _state(7, true, 130e6, 70e6);

        vm.recordLogs();
        adjudicator.concludeAndTransferAllAssets(fixedPart, _signedByBoth(fixedPart, finalState));

        _assertShieldedToUser(vm.getRecordedLogs(), 130e6);
        assertEq(usdc.balanceOf(address(custodian)), 70e6);
        assertEq(adjudicator.heldValue(address(usdc), _channelId(fixedPart)), 0);
    }

    function test_forceClose_userExitsToNoteWhenHubStopsResponding() public {
        FixedPart memory fixedPart = _fixedPart(address(consensusApp));
        bytes32 channelId = _channelId(fixedPart);
        _fundChannel(channelId);
        VariablePart memory latest = _state(12, false, 150e6, 50e6);

        vm.prank(broadcaster);
        adjudicator.challenge(
            fixedPart,
            new SignedVariablePart[](0),
            _signedByBoth(fixedPart, latest),
            _challengerSig(USER_KEY, fixedPart, latest)
        );
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);

        vm.recordLogs();
        adjudicator.transferAllAssets(channelId, latest.outcome, NitroUtils.hashState(fixedPart, latest));

        _assertShieldedToUser(vm.getRecordedLogs(), 150e6);
        assertEq(usdc.balanceOf(address(custodian)), 50e6);
    }

    function test_staleHubChallenge_isOverriddenByUsersLatestState() public {
        FixedPart memory fixedPart = _fixedPart(address(consensusApp));
        bytes32 channelId = _channelId(fixedPart);
        _fundChannel(channelId);
        VariablePart memory stale = _state(3, false, 60e6, 140e6);
        VariablePart memory latest = _state(9, false, 160e6, 40e6);

        // The hub's delegate challenges with an old state that favours the hub.
        adjudicator.challenge(
            fixedPart,
            new SignedVariablePart[](0),
            _signedByBoth(fixedPart, stale),
            _challengerSig(DELEGATE_KEY, fixedPart, stale)
        );
        // The user's watchtower answers inside the window with the latest co-signed state.
        adjudicator.challenge(
            fixedPart,
            new SignedVariablePart[](0),
            _signedByBoth(fixedPart, latest),
            _challengerSig(USER_KEY, fixedPart, latest)
        );
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);

        vm.recordLogs();
        adjudicator.transferAllAssets(channelId, latest.outcome, NitroUtils.hashState(fixedPart, latest));

        _assertShieldedToUser(vm.getRecordedLogs(), 160e6);
        assertEq(usdc.balanceOf(address(custodian)), 40e6);
    }

    // ---------------------------------------------------------------- delegate revocation

    function test_revokedDelegate_statesRegisteredDuringDelayStillSettle() public {
        FixedPart memory fixedPart = _fixedPart(address(consensusApp));
        bytes32 channelId = _channelId(fixedPart);
        _fundChannel(channelId);
        VariablePart memory latest = _state(5, false, 120e6, 80e6);
        SignedVariablePart memory signedLatest = _signedByBoth(fixedPart, latest);

        _hubExecute(address(custodian), abi.encodeCall(IHubCustodian.revokeDelegate, (delegate)));
        // Inside the delay the hub's delegate signature still verifies; the user registers the state.
        vm.warp(block.timestamp + REVOCATION_DELAY - 1);
        adjudicator.challenge(
            fixedPart,
            new SignedVariablePart[](0),
            signedLatest,
            _challengerSig(USER_KEY, fixedPart, latest)
        );

        // Past the revocation and the challenge window, the registered outcome pays out unchanged.
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
        assertFalse(custodian.isActiveDelegate(delegate));
        vm.recordLogs();
        adjudicator.transferAllAssets(channelId, latest.outcome, NitroUtils.hashState(fixedPart, latest));
        _assertShieldedToUser(vm.getRecordedLogs(), 120e6);
    }

    function test_revokedDelegate_unregisteredStateIsRejectedAfterDelay() public {
        FixedPart memory fixedPart = _fixedPart(address(consensusApp));
        _fundChannel(_channelId(fixedPart));
        VariablePart memory latest = _state(5, false, 120e6, 80e6);
        SignedVariablePart memory signedLatest = _signedByBoth(fixedPart, latest);

        _hubExecute(address(custodian), abi.encodeCall(IHubCustodian.revokeDelegate, (delegate)));
        vm.warp(block.timestamp + REVOCATION_DELAY);

        Signature memory challengerSig = _challengerSig(USER_KEY, fixedPart, latest);
        vm.expectRevert('!unanimous');
        adjudicator.challenge(fixedPart, new SignedVariablePart[](0), signedLatest, challengerSig);
    }

    // ---------------------------------------------------------------- hostile participants

    function test_hostileContractParticipant_cannotExhaustACounterpartysChallenge() public {
        address[] memory participants = new address[](2);
        participants[0] = address(new GasBombParticipant());
        participants[1] = user;
        FixedPart memory fixedPart = FixedPart({
            participants: participants,
            channelNonce: 1,
            appDefinition: address(new AlwaysSupportedApp()),
            challengeDuration: CHALLENGE_DURATION
        });
        VariablePart memory state = _state(1, false, 0, 0);
        Signature[] memory sigs = new Signature[](1);
        sigs[0] = _sign(USER_KEY, fixedPart, state);

        // Each EIP-1271 probe of the hostile participant is capped at EIP1271_GAS.
        adjudicator.challenge{gas: 1_000_000}(
            fixedPart,
            new SignedVariablePart[](0),
            SignedVariablePart({variablePart: state, sigs: sigs}),
            _challengerSig(USER_KEY, fixedPart, state)
        );
        (uint48 turnNumRecord, uint48 finalizesAt, ) = adjudicator.unpackStatus(_channelId(fixedPart));
        assertEq(turnNumRecord, 1);
        assertEq(finalizesAt, block.timestamp + CHALLENGE_DURATION);
    }

    // ---------------------------------------------------------------- helpers

    function _fixedPart(address app) internal view returns (FixedPart memory) {
        return ChannelStates.fixedPart(user, address(custodian), 1, app, CHALLENGE_DURATION);
    }

    function _channelId(FixedPart memory fixedPart) internal pure returns (bytes32) {
        return NitroUtils.getChannelId(fixedPart);
    }

    /// @dev User funds from a shielded note; the hub funds from custodian inventory, also via a
    /// shielded note (N1a: a channel is funded only through depositFromNote, never a raw transfer).
    function _fundChannel(bytes32 channelId) internal {
        _shield(user, USER_DEPOSIT_NPK, USER_FUNDS);
        _depositFromNote(channelId, 0, USER_FUNDS);

        bytes32 hubNpk = bytes32(uint256(0x4444) + uint256(uint160(address(custodian))));
        usdc.mint(address(custodian), HUB_FUNDS);
        _hubExecute(address(usdc), abi.encodeWithSignature('approve(address,uint256)', address(pool), HUB_FUNDS));
        _hubExecute(
            address(pool),
            abi.encodeCall(
                pool.shield,
                (ArmadaNotes.shieldRequests(address(usdc), hubNpk, HUB_FUNDS), address(0))
            )
        );
        Transaction[] memory hubTxs = _unshield(
            address(adjudicator),
            HUB_FUNDS,
            address(adjudicator),
            adjudicator.depositBinding(channelId, USER_FUNDS),
            USER_FUNDS
        );
        vm.prank(broadcaster);
        adjudicator.depositFromNote(channelId, USER_FUNDS, hubTxs);
        assertEq(adjudicator.heldValue(address(usdc), channelId), USER_FUNDS + HUB_FUNDS);
    }

    function _depositFromNote(bytes32 channelId, uint256 expectedHeld, uint120 value) internal {
        Transaction[] memory txs = _unshield(
            address(adjudicator),
            value,
            address(adjudicator),
            adjudicator.depositBinding(channelId, expectedHeld),
            expectedHeld
        );
        vm.prank(broadcaster);
        adjudicator.depositFromNote(channelId, expectedHeld, txs);
    }

    function _state(
        uint48 turnNum,
        bool isFinal,
        uint256 userAmount,
        uint256 hubAmount
    ) internal view returns (VariablePart memory) {
        return
            ChannelStates.state(
                address(usdc),
                USER_PAYOUT_NPK,
                address(custodian),
                turnNum,
                isFinal,
                userAmount,
                hubAmount
            );
    }

    function _sign(
        uint256 key,
        FixedPart memory fixedPart,
        VariablePart memory state
    ) internal pure returns (Signature memory) {
        return ChannelStates.sign(key, fixedPart, state);
    }

    function _signedByBoth(
        FixedPart memory fixedPart,
        VariablePart memory state
    ) internal pure returns (SignedVariablePart memory) {
        return ChannelStates.signedByBoth(USER_KEY, DELEGATE_KEY, fixedPart, state);
    }

    function _challengerSig(
        uint256 key,
        FixedPart memory fixedPart,
        VariablePart memory state
    ) internal pure returns (Signature memory) {
        return ChannelStates.challengerSig(key, fixedPart, state);
    }

    function _hubExecute(address target, bytes memory data) internal {
        bytes32 message = custodian.operationHash(custodian.nonce(), target, 0, data);
        (uint256 rx, uint256 ry, uint256 z) = frost.sign(GROUP_SCALAR, message);
        custodian.execute(target, 0, data, IHubCustodian.GroupSignature(rx, ry, z));
    }

    function _assertShieldedToUser(Vm.Log[] memory logs, uint256 amount) internal view {
        (CommitmentPreimage[] memory notes, ShieldCiphertext[] memory ciphertexts) = _shieldedNotes(logs);
        assertEq(notes.length, 1, 'one note shielded');
        assertEq(notes[0].npk, USER_PAYOUT_NPK);
        assertEq(notes[0].token.tokenAddress, address(usdc));
        assertEq(uint256(notes[0].value), amount);
        assertEq(abi.encode(ciphertexts[0]), abi.encode(ArmadaNotes.ciphertext(USER_PAYOUT_NPK)));
    }
}
