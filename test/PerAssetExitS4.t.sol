// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test, Vm} from 'forge-std/Test.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';
import {ArmadaNitroAdjudicator, SHIELD_ALLOCATION_TYPE} from 'src/ArmadaNitroAdjudicator.sol';
import {ConsensusApp} from 'src/nitro/ConsensusApp.sol';
import {NitroUtils} from 'src/nitro/libraries/NitroUtils.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {IHubCustodian, IFrostTestSigner} from './helpers/IHubCustodian.sol';
import {ArmadaFixture} from './helpers/ArmadaFixture.sol';
import {ArmadaNotes} from './helpers/ArmadaNotes.sol';
import {RevertingTransferToken} from './helpers/RevertingTransferToken.sol';
import {ChannelStates} from './helpers/ChannelStates.sol';
import {IArmadaPool, CommitmentPreimage, ShieldCiphertext, Transaction} from 'src/armada/IArmadaPool.sol';

/// @dev arn-bfc (E16 S4): proves the per-asset-exit invariant. In a two-asset channel whose
/// second token (RevertingTransferToken) always reverts on transfer, the single-asset exit
/// `transfer(assetIndex)` still pays out the other (good) asset, while `transferAllAssets`
/// reverts as a whole (no partial payout).
contract PerAssetExitS4Test is ArmadaFixture, INitroTypes {
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
    bytes32 internal constant USER2_PAYOUT_NPK = bytes32(uint256(0x3333));

    ArmadaNitroAdjudicator internal adjudicator;
    ConsensusApp internal consensusApp;
    IHubCustodian internal custodian;
    IFrostTestSigner internal frost;
    RevertingTransferToken internal revToken;
    address internal user;
    address internal delegate;
    address internal broadcaster = address(0xB0CA);

    function setUp() public {
        _deployArmada();
        // the constructor mints HUB_FUNDS of the reverting token to the test contract (msg.sender)
        revToken = new RevertingTransferToken(HUB_FUNDS);

        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(revToken);
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

    // c1: the single-asset exit `transfer(assetIndex)` still pays out the other (good) asset.
    function test_transfer_assetIndex_paysOtherAsset_whenPairedTokenReverts() public {
        FixedPart memory fp = _fixedPart(address(consensusApp));
        bytes32 channelId = _channelId(fp);
        _fundTwoAssetChannel(channelId);

        VariablePart memory state = _twoAssetState(12, USER_FUNDS, HUB_FUNDS);
        bytes32 stateHash = NitroUtils.hashState(fp, state);
        SignedVariablePart memory signedState = _signedByBoth(fp, state);
        bytes memory outcomeBytes = abi.encode(state.outcome);

        adjudicator.challenge(
            fp,
            new SignedVariablePart[](0),
            signedState,
            _challengerSig(USER_KEY, fp, state)
        );
        // Let the challenge window expire, finalizing the channel.
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);

        // Single-asset exit: pay out the other (USDC) asset via `transfer(assetIndex, ...)`.
        adjudicator.transfer(0, channelId, outcomeBytes, stateHash, new uint256[](0));

        // The other asset (USDC) is fully paid out; the reverting asset is untouched.
        assertEq(adjudicator.holdings(address(usdc), channelId), 0);
        assertEq(adjudicator.holdings(address(revToken), channelId), HUB_FUNDS);
    }

    // c2: the all-assets exit `transferAllAssets` reverts as a whole (no partial payout).
    function test_transferAllAssets_revertsAsWhole_whenPairedTokenReverts() public {
        FixedPart memory fp = _fixedPart(address(consensusApp));
        bytes32 channelId = _channelId(fp);
        _fundTwoAssetChannel(channelId);

        VariablePart memory state = _twoAssetState(12, USER_FUNDS, HUB_FUNDS);
        bytes32 stateHash = NitroUtils.hashState(fp, state);
        SignedVariablePart memory signedState = _signedByBoth(fp, state);

        adjudicator.challenge(
            fp,
            new SignedVariablePart[](0),
            signedState,
            _challengerSig(USER_KEY, fp, state)
        );
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);

        // The all-assets exit reverts as a whole because the reverting token blocks its transfer.
        vm.expectRevert();
        adjudicator.transferAllAssets(channelId, state.outcome, stateHash);

        // No partial payout: both assets' holdings are unchanged.
        assertEq(adjudicator.holdings(address(usdc), channelId), USER_FUNDS + HUB_FUNDS);
        assertEq(adjudicator.holdings(address(revToken), channelId), HUB_FUNDS);
    }

    // ---------------------------------------------------------------- helpers

    function _fixedPart(address app) internal view returns (FixedPart memory) {
        address[] memory participants = new address[](2);
        participants[0] = user;
        participants[1] = address(custodian);
        return
            INitroTypes.FixedPart({
                participants: participants,
                channelNonce: 1,
                appDefinition: app,
                challengeDuration: CHALLENGE_DURATION
            });
    }

    function _channelId(FixedPart memory fp) internal pure returns (bytes32) {
        return NitroUtils.getChannelId(fp);
    }

    /// @dev Funds the channel with both assets: USDC via the user's note + the hub's custodian,
    /// and the reverting token via a direct deposit (transferFrom is standard, only transfer reverts).
    function _fundTwoAssetChannel(bytes32 channelId) internal {
        // USDC: user note + hub custodian.
        _shield(user, USER_DEPOSIT_NPK, USER_FUNDS);
        _depositFromNote(channelId, 0, USER_FUNDS);
        usdc.mint(address(custodian), HUB_FUNDS);
        _hubExecute(address(usdc), abi.encodeWithSignature('approve(address,uint256)', address(adjudicator), HUB_FUNDS));
        _hubExecute(
            address(adjudicator),
            abi.encodeCall(adjudicator.deposit, (address(usdc), channelId, USER_FUNDS, HUB_FUNDS))
        );
        assertEq(adjudicator.holdings(address(usdc), channelId), USER_FUNDS + HUB_FUNDS);

        // RevertingTransferToken: the test contract holds HUB_FUNDS from the constructor mint.
        revToken.approve(address(adjudicator), HUB_FUNDS);
        adjudicator.deposit(address(revToken), channelId, 0, HUB_FUNDS);
        assertEq(adjudicator.holdings(address(revToken), channelId), HUB_FUNDS);
    }

    /// @dev Builds the two-asset state: USDC (asset 0, the good asset) + RevertingTransferToken
    /// (asset 1, the reverting asset). Each asset pays the user via a shielded note (SHIELD) and
    /// the hub via the custodian (simple).
    function _twoAssetState(
        uint48 turnNum,
        uint256 userAmount,
        uint256 hubAmount
    ) internal view returns (VariablePart memory) {
        Outcome.Allocation[] memory usdcAlloc = new Outcome.Allocation[](2);
        usdcAlloc[0] = Outcome.Allocation(
            USER_PAYOUT_NPK,
            userAmount,
            SHIELD_ALLOCATION_TYPE,
            abi.encode(ArmadaNotes.ciphertext(USER_PAYOUT_NPK))
        );
        usdcAlloc[1] = Outcome.Allocation(
            _addressToBytes32(address(custodian)),
            hubAmount,
            uint8(Outcome.AllocationType.simple),
            ''
        );

        Outcome.Allocation[] memory revAlloc = new Outcome.Allocation[](2);
        revAlloc[0] = Outcome.Allocation(
            USER2_PAYOUT_NPK,
            userAmount,
            SHIELD_ALLOCATION_TYPE,
            abi.encode(ArmadaNotes.ciphertext(USER2_PAYOUT_NPK))
        );
        revAlloc[1] = Outcome.Allocation(
            _addressToBytes32(address(custodian)),
            hubAmount,
            uint8(Outcome.AllocationType.simple),
            ''
        );

        Outcome.SingleAssetExit[] memory outcome = new Outcome.SingleAssetExit[](2);
        outcome[0] = Outcome.SingleAssetExit(address(usdc), Outcome.AssetMetadata(Outcome.AssetType.Default, ''), usdcAlloc);
        outcome[1] = Outcome.SingleAssetExit(address(revToken), Outcome.AssetMetadata(Outcome.AssetType.Default, ''), revAlloc);
        return
            INitroTypes.VariablePart({
                outcome: outcome,
                appData: '',
                turnNum: turnNum,
                isFinal: true
            });
    }

    function _depositFromNote(bytes32 channelId, uint256 expectedHeld, uint120 value) internal {
        Transaction[] memory txs = _unshield(
            address(adjudicator),
            value,
            address(adjudicator),
            adjudicator.depositBinding(channelId, expectedHeld)
        );
        vm.prank(broadcaster);
        adjudicator.depositFromNote(channelId, expectedHeld, txs);
    }

    function _signedByBoth(
        FixedPart memory fp,
        VariablePart memory state
    ) internal pure returns (SignedVariablePart memory) {
        return ChannelStates.signedByBoth(USER_KEY, DELEGATE_KEY, fp, state);
    }

    function _challengerSig(
        uint256 key,
        FixedPart memory fp,
        VariablePart memory state
    ) internal pure returns (Signature memory) {
        return ChannelStates.challengerSig(key, fp, state);
    }

    function _hubExecute(address target, bytes memory data) internal {
        bytes32 message = custodian.operationHash(custodian.nonce(), target, 0, data);
        (uint256 rx, uint256 ry, uint256 z) = frost.sign(GROUP_SCALAR, message);
        custodian.execute(target, 0, data, IHubCustodian.GroupSignature(rx, ry, z));
    }

    function _addressToBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
