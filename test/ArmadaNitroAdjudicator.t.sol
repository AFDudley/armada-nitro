// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Vm} from 'forge-std/Test.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {ConsensusApp} from 'src/nitro/ConsensusApp.sol';
import {NitroUtils} from 'src/nitro/libraries/NitroUtils.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {IForceMoveApp} from 'src/nitro/interfaces/IForceMoveApp.sol';
import {IMultiAssetHolder} from 'src/nitro/interfaces/IMultiAssetHolder.sol';
import {CommitmentPreimage, ShieldCiphertext, TokenData, TokenType, Transaction} from 'src/armada/IArmadaPool.sol';
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
        bytes32 channelId = _channelId(_fixedPart(address(consensusApp)));
        _shield(user, USER_DEPOSIT_NPK, USER_FUNDS);

        _depositFromNote(channelId, 0, USER_FUNDS);

        assertEq(adjudicator.heldValue(address(usdc), channelId), USER_FUNDS);
        assertEq(usdc.balanceOf(address(adjudicator)), USER_FUNDS);
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

    // ---------------------------------------------------------------- settlement

    function test_cooperativeClose_shieldsUserNoteAndPaysCustodian() public {
        FixedPart memory fixedPart = _fixedPart(address(consensusApp));
        _fundChannel(_channelId(fixedPart));
        VariablePart memory finalState = _state(7, true, 130e6, 70e6);

        uint256 custodianBalBefore = usdc.balanceOf(address(custodian));
        vm.recordLogs();
        adjudicator.concludeAndTransferAllAssets(fixedPart, _signedByBoth(fixedPart, finalState));

        _assertShieldedToUser(vm.getRecordedLogs(), 130e6);
        // N1b: the hub's share is paid as a pool commitment, not a raw ERC20 transfer.
        assertEq(usdc.balanceOf(address(custodian)), custodianBalBefore, 'no raw ERC20 reaches the custodian');
        assertEq(uint256(_custodianCommitmentPreimage(70e6).value), 70e6, 'custodian paid via a fresh commitment');
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

        uint256 custodianBalBefore = usdc.balanceOf(address(custodian));
        vm.recordLogs();
        adjudicator.transferAllAssets(channelId, latest.outcome, NitroUtils.hashState(fixedPart, latest));

        _assertShieldedToUser(vm.getRecordedLogs(), 150e6);
        // N1b: the hub's share is paid as a pool commitment, not a raw ERC20 transfer.
        assertEq(usdc.balanceOf(address(custodian)), custodianBalBefore, 'no raw ERC20 reaches the custodian');
        assertEq(uint256(_custodianCommitmentPreimage(50e6).value), 50e6, 'custodian paid via a fresh commitment');
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

        uint256 custodianBalBefore = usdc.balanceOf(address(custodian));
        vm.recordLogs();
        adjudicator.transferAllAssets(channelId, latest.outcome, NitroUtils.hashState(fixedPart, latest));

        _assertShieldedToUser(vm.getRecordedLogs(), 160e6);
        // N1b: the hub's share is paid as a pool commitment, not a raw ERC20 transfer.
        assertEq(usdc.balanceOf(address(custodian)), custodianBalBefore, 'no raw ERC20 reaches the custodian');
        assertEq(uint256(_custodianCommitmentPreimage(40e6).value), 40e6, 'custodian paid via a fresh commitment');
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

    // ---------------------------------------------------------------- N1b: collateral as pool commitments

    /// @dev c1: a partial transfer pays the named destination a fresh owned commitment of the paid amount.
    function test_transfer_partial_pays_destination_fresh_commitment() public {
        (bytes32 channelId, uint256 hubAmount, , bytes32 custodianCommitment) = _setUpPartialTransfer();
        channelId; // silence unused-var warning (consumed for setup only)

        CommitmentPreimage memory preimage = pool.preimageOf(custodianCommitment);
        assertEq(preimage.token.tokenAddress, address(usdc), 'commitment is a USDC note');
        assertEq(uint256(preimage.value), hubAmount, 'destination commitment worth exactly the paid amount');
        assertEq(preimage.npk, bytes32(uint256(uint160(address(custodian)))), 'commitment owned by the named destination');
    }

    /// @dev c2: after a partial transfer, the channel's holding points at a fresh commitment of the remainder.
    function test_transfer_partial_leaves_fresh_remainder_commitment() public {
        (bytes32 channelId, , uint256 userAmount, ) = _setUpPartialTransfer();

        bytes32 remainderCommitment = adjudicator.holdings(address(usdc), channelId);
        assertTrue(remainderCommitment != bytes32(0), 'channel still points at a commitment');
        CommitmentPreimage memory preimage = pool.preimageOf(remainderCommitment);
        assertEq(uint256(preimage.value), userAmount, 'remainder commitment worth exactly the remainder');
        assertEq(adjudicator.heldValue(address(usdc), channelId), userAmount, 'heldValue reflects the remainder live');
    }

    /// @dev c3: after a transfer that pays out all of the collateral in one asset, the channel's holding
    /// for that asset is the zero value.
    function test_transfer_full_payout_zeroes_holding() public {
        FixedPart memory fixedPart = _fixedPart(address(consensusApp));
        bytes32 channelId = _channelId(fixedPart);
        _fundChannel(channelId);

        uint256 hubAmount = HUB_FUNDS;
        uint256 userAmount = USER_FUNDS;
        VariablePart memory state = _state(12, false, userAmount, hubAmount);
        bytes32 stateHash = NitroUtils.hashState(fixedPart, state);
        bytes memory outcomeBytes = abi.encode(state.outcome);

        adjudicator.challenge(
            fixedPart,
            new SignedVariablePart[](0),
            _signedByBoth(fixedPart, state),
            _challengerSig(USER_KEY, fixedPart, state)
        );
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);

        // Pay out everything in one asset (indices == [] means "all").
        adjudicator.transfer(0, channelId, outcomeBytes, stateHash, new uint256[](0));

        assertEq(adjudicator.holdings(address(usdc), channelId), bytes32(0), 'full payout zeroes the holding');
        assertEq(adjudicator.heldValue(address(usdc), channelId), 0, 'heldValue reads zero for an empty commitment');
    }

    /// @dev c4: after a reclaim, the target channel's held value is larger by exactly the guarantee value.
    function test_reclaim_raises_target_heldValue_by_guarantee_value() public {
        uint256 leftKey = 0x1EF7;
        uint256 rightKey = 0x1217;
        bytes32 leftDest = bytes32(uint256(uint160(vm.addr(leftKey))));
        bytes32 rightDest = bytes32(uint256(uint160(vm.addr(rightKey))));
        uint256 leftTargetAmount = 5e6;
        uint256 rightTargetAmount = 3e6;
        uint256 guaranteeAmount = leftTargetAmount + rightTargetAmount;

        (bytes32 targetChannelId, bytes32 targetStateHash, bytes memory targetOutcomeBytes, uint256 priorTargetHeld) =
            _finalizeReclaimTarget(leftKey, leftDest, rightDest, leftTargetAmount, rightTargetAmount);

        (
            bytes32 sourceChannelId,
            FixedPart memory sourceFixedPart,
            VariablePart memory sourceVariablePart,
            bytes memory sourceOutcomeBytes
        ) = _finalizeReclaimSource(leftKey, leftDest, rightDest, targetChannelId, guaranteeAmount);

        adjudicator.reclaim(
            IMultiAssetHolder.ReclaimArgs({
                sourceChannelId: sourceChannelId,
                fixedPart: sourceFixedPart,
                variablePart: sourceVariablePart,
                sourceOutcomeBytes: sourceOutcomeBytes,
                sourceAssetIndex: 0,
                indexOfTargetInSource: 1,
                targetStateHash: targetStateHash,
                targetOutcomeBytes: targetOutcomeBytes,
                targetAssetIndex: 0
            })
        );

        uint256 newTargetHeld = adjudicator.heldValue(address(usdc), targetChannelId);
        assertEq(newTargetHeld, priorTargetHeld + guaranteeAmount, 'target heldValue rises by exactly the guarantee value');
    }

    /// @dev Challenges `fixedPart`/`variablePart` with `signerKey`'s signature, then warps past
    /// the challenge window so the channel finalizes. Shared by the reclaim test's two channels.
    function _challengeAndWarp(
        FixedPart memory fixedPart,
        uint256 signerKey,
        VariablePart memory variablePart
    ) internal {
        Signature[] memory sigs = new Signature[](1);
        sigs[0] = ChannelStates.sign(signerKey, fixedPart, variablePart);
        adjudicator.challenge(
            fixedPart,
            new SignedVariablePart[](0),
            SignedVariablePart({variablePart: variablePart, sigs: sigs}),
            ChannelStates.challengerSig(signerKey, fixedPart, variablePart)
        );
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);
    }

    function _twoAllocationOutcome(
        bytes32 destA,
        uint256 amountA,
        bytes32 destB,
        uint256 amountB
    ) internal view returns (Outcome.SingleAssetExit[] memory outcome) {
        Outcome.Allocation[] memory allocations = new Outcome.Allocation[](2);
        allocations[0] = Outcome.Allocation(destA, amountA, uint8(Outcome.AllocationType.simple), '');
        allocations[1] = Outcome.Allocation(destB, amountB, uint8(Outcome.AllocationType.simple), '');
        outcome = new Outcome.SingleAssetExit[](1);
        outcome[0] = Outcome.SingleAssetExit(address(usdc), Outcome.AssetMetadata(Outcome.AssetType.Default, ''), allocations);
    }

    /// @dev Funds then finalizes the reclaim test's target channel with its own (unrelated)
    /// closing outcome, split between leftDest/rightDest.
    function _finalizeReclaimTarget(
        uint256 leftKey,
        bytes32 leftDest,
        bytes32 rightDest,
        uint256 leftAmount,
        uint256 rightAmount
    ) internal returns (bytes32 channelId, bytes32 stateHash, bytes memory outcomeBytes, uint256 priorHeld) {
        FixedPart memory fixedPart = FixedPart({
            participants: _twoParticipants(vm.addr(leftKey), address(uint160(uint256(rightDest)))),
            channelNonce: 777,
            appDefinition: address(new AlwaysSupportedApp()),
            challengeDuration: CHALLENGE_DURATION
        });
        channelId = NitroUtils.getChannelId(fixedPart);
        _shield(user, USER_DEPOSIT_NPK, USER_FUNDS);
        _depositFromNote(channelId, 0, USER_FUNDS);
        priorHeld = adjudicator.heldValue(address(usdc), channelId);
        assertEq(priorHeld, USER_FUNDS, 'target funded before finalizing');

        VariablePart memory variablePart = VariablePart({
            outcome: _twoAllocationOutcome(leftDest, leftAmount, rightDest, rightAmount),
            appData: '',
            turnNum: 1,
            isFinal: false
        });
        stateHash = NitroUtils.hashState(fixedPart, variablePart);
        _challengeAndWarp(fixedPart, leftKey, variablePart);
        outcomeBytes = abi.encode(variablePart.outcome);
    }

    /// @dev Finalizes the reclaim test's source (ledger) channel: a guarantee for the target,
    /// plus its own left/right allocations (outside the guarantee) that the guarantee reclaims
    /// value into.
    function _finalizeReclaimSource(
        uint256 leftKey,
        bytes32 leftDest,
        bytes32 rightDest,
        bytes32 targetChannelId,
        uint256 guaranteeAmount
    )
        internal
        returns (
            bytes32 channelId,
            FixedPart memory fixedPart,
            VariablePart memory variablePart,
            bytes memory outcomeBytes
        )
    {
        fixedPart = FixedPart({
            participants: _twoParticipants(vm.addr(leftKey), address(uint160(uint256(rightDest)))),
            channelNonce: 888,
            appDefinition: address(new AlwaysSupportedApp()),
            challengeDuration: CHALLENGE_DURATION
        });
        channelId = NitroUtils.getChannelId(fixedPart);
        variablePart = VariablePart({
            outcome: _sourceGuaranteeOutcome(leftDest, rightDest, targetChannelId, guaranteeAmount),
            appData: '',
            turnNum: 1,
            isFinal: false
        });
        _challengeAndWarp(fixedPart, leftKey, variablePart);
        outcomeBytes = abi.encode(variablePart.outcome);
    }

    function _sourceGuaranteeOutcome(
        bytes32 leftDest,
        bytes32 rightDest,
        bytes32 targetChannelId,
        uint256 guaranteeAmount
    ) internal view returns (Outcome.SingleAssetExit[] memory outcome) {
        Outcome.Allocation[] memory allocations = new Outcome.Allocation[](3);
        allocations[0] = Outcome.Allocation(leftDest, 2e6, uint8(Outcome.AllocationType.simple), '');
        allocations[1] = Outcome.Allocation(
            targetChannelId,
            guaranteeAmount,
            uint8(Outcome.AllocationType.guarantee),
            abi.encode(leftDest, rightDest)
        );
        allocations[2] = Outcome.Allocation(rightDest, 2e6, uint8(Outcome.AllocationType.simple), '');
        outcome = new Outcome.SingleAssetExit[](1);
        outcome[0] = Outcome.SingleAssetExit(address(usdc), Outcome.AssetMetadata(Outcome.AssetType.Default, ''), allocations);
    }

    /// @dev c5: paying out to an external destination through the adjudicator moves value as pool
    /// commitments and sends no raw asset directly.
    function test_exit_external_destination_pays_commitment_not_raw_asset() public {
        FixedPart memory fixedPart = _fixedPart(address(consensusApp));
        _fundChannel(_channelId(fixedPart));
        VariablePart memory finalState = _state(7, true, 130e6, 70e6);

        uint256 custodianBalBefore = usdc.balanceOf(address(custodian));

        adjudicator.concludeAndTransferAllAssets(fixedPart, _signedByBoth(fixedPart, finalState));

        // No raw asset moved to the custodian's wallet.
        assertEq(usdc.balanceOf(address(custodian)), custodianBalBefore, 'no raw ERC20 transfer to the custodian');

        // Instead, the custodian holds a fresh pool commitment worth its allocation.
        bytes32 custodianCommitment = ArmadaNotes.commitmentHash(
            CommitmentPreimage({
                npk: bytes32(uint256(uint160(address(custodian)))),
                token: TokenData({tokenType: TokenType.ERC20, tokenAddress: address(usdc), tokenSubID: 0}),
                value: uint120(70e6)
            })
        );
        CommitmentPreimage memory preimage = pool.preimageOf(custodianCommitment);
        assertEq(uint256(preimage.value), 70e6, 'custodian paid via a pool commitment, not a raw transfer');
    }

    /// @dev Shared setup for the two partial-transfer tests (c1/c2): funds a standard channel,
    /// challenges with a SHIELD (user) + simple (custodian) state, warps to finalize, then
    /// transfers only the custodian's (index 1) share.
    function _setUpPartialTransfer()
        internal
        returns (bytes32 channelId, uint256 hubAmount, uint256 userAmount, bytes32 custodianCommitment)
    {
        FixedPart memory fixedPart = _fixedPart(address(consensusApp));
        channelId = _channelId(fixedPart);
        _fundChannel(channelId);

        hubAmount = HUB_FUNDS;
        userAmount = USER_FUNDS;
        VariablePart memory state = _state(12, false, userAmount, hubAmount);
        bytes32 stateHash = NitroUtils.hashState(fixedPart, state);
        bytes memory outcomeBytes = abi.encode(state.outcome);

        adjudicator.challenge(
            fixedPart,
            new SignedVariablePart[](0),
            _signedByBoth(fixedPart, state),
            _challengerSig(USER_KEY, fixedPart, state)
        );
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);

        uint256[] memory indices = new uint256[](1);
        indices[0] = 1; // pay out only the custodian's (index 1) share
        adjudicator.transfer(0, channelId, outcomeBytes, stateHash, indices);

        custodianCommitment = ArmadaNotes.commitmentHash(
            CommitmentPreimage({
                npk: bytes32(uint256(uint160(address(custodian)))),
                token: TokenData({tokenType: TokenType.ERC20, tokenAddress: address(usdc), tokenSubID: 0}),
                value: uint120(hubAmount)
            })
        );
    }

    function _twoParticipants(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
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

    /// @dev N1b: the custodian's fresh pool commitment for a given payout value (a mint-only
    /// transactOwned output, keyed by the custodian's address as npk, same encoding as a "simple"
    /// external destination).
    function _custodianCommitmentPreimage(uint256 value) internal view returns (CommitmentPreimage memory) {
        bytes32 commitment = ArmadaNotes.commitmentHash(
            CommitmentPreimage({
                npk: bytes32(uint256(uint160(address(custodian)))),
                token: TokenData({tokenType: TokenType.ERC20, tokenAddress: address(usdc), tokenSubID: 0}),
                value: uint120(value)
            })
        );
        return pool.preimageOf(commitment);
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
