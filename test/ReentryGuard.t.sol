// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test} from 'forge-std/Test.sol';
import {console} from 'forge-std/console.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {
    IArmadaPool,
    BoundParams,
    CommitmentCiphertext,
    CommitmentPreimage,
    G1Point,
    G2Point,
    ShieldRequest,
    SnarkProof,
    TokenData,
    TokenType,
    Transaction,
    UnshieldType
} from 'src/armada/IArmadaPool.sol';
import {IMultiAssetHolder} from 'src/nitro/interfaces/IMultiAssetHolder.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {NitroUtils} from 'src/nitro/libraries/NitroUtils.sol';
import {MockUSDCV2} from 'armada/cctp/MockUSDCV2.sol';
import {ChannelStates} from './helpers/ChannelStates.sol';

/// @dev A no-op Armada pool: never actually invoked in these tests, since the reentrancy guard
/// reverts `depositFromNote` before it reaches `pool.transact`.
contract NoopPool is IArmadaPool {
    function shield(ShieldRequest[] calldata, address) external {}

    function transact(Transaction[] calldata) external {}

    function preimageOf(bytes32) external pure returns (CommitmentPreimage memory) {
        return CommitmentPreimage({npk: bytes32(0), token: TokenData({tokenType: TokenType.ERC20, tokenAddress: address(0), tokenSubID: 0}), value: 0});
    }

    function transactOwned(Transaction[] calldata) external {}
}

/// @dev Exposes test-only setters so each of the six holdings-mutating entry points can be
/// exercised with `holdingsLock` already set, faithfully simulating "a call on this channel is
/// still in progress" (the exact condition the production guard checks), and so channels can be
/// finalized directly without running a full challenge/conclude dance.
contract AdjudicatorHarness is ArmadaNitroAdjudicator {
    constructor(
        IArmadaPool pool_,
        address[] memory assets_
    ) ArmadaNitroAdjudicator(pool_, assets_) {}

    function setHoldingsLock(bytes32 channelId, uint256 value) external {
        holdingsLock[channelId] = value;
    }

    function finalize(bytes32 channelId, bytes32 stateHash, bytes memory outcomeBytes) external {
        statusOf[channelId] = _generateStatus(
            ChannelData(0, uint48(block.timestamp), stateHash, keccak256(outcomeBytes))
        );
    }
}

/// c2 (no-nested-call-while-in-progress): none of deposit, depositFromNote, transfer,
/// transferAllAssets, concludeAndTransferAllAssets or reclaim accept a nested call on a channel
/// that already has a call in progress; each reverts with 'Re-entered while in progress' and
/// leaves holdings exactly as they were before the attempt.
contract ReentryGuardTest is Test, INitroTypes {
    AdjudicatorHarness internal adjudicator;
    address internal constant ASSET = address(0xA55E7);
    string internal constant GUARD_REVERT = 'Re-entered while in progress';
    MockUSDCV2 internal token;

    function setUp() public {
        token = new MockUSDCV2('ReentryGuardToken', 'RG');
        address[] memory assets = new address[](2);
        assets[0] = ASSET;
        assets[1] = address(token);
        adjudicator = new AdjudicatorHarness(new NoopPool(), assets);
        vm.warp(1_000);
    }

    // N1a: the base `deposit` entry point is gone; `test_guard_depositFromNote_revertsWhileInProgress`
    // below is this guard's sole (and now only possible) funding-path coverage.
    function test_guard_depositFromNote_revertsWhileInProgress() public {
        bytes32 channelId = keccak256('guard depositFromNote channel');

        Transaction[] memory txs = new Transaction[](1);
        txs[0] = Transaction({
            proof: SnarkProof({
                a: G1Point(0, 0),
                b: G2Point([uint256(0), 0], [uint256(0), 0]),
                c: G1Point(0, 0)
            }),
            merkleRoot: bytes32(0),
            nullifiers: new bytes32[](0),
            commitments: new bytes32[](0),
            boundParams: BoundParams({
                treeNumber: 0,
                minGasPrice: 0,
                unshield: UnshieldType.NORMAL,
                chainID: uint64(block.chainid),
                adaptContract: address(adjudicator),
                adaptParams: adjudicator.depositBinding(channelId, 0),
                commitmentCiphertext: new CommitmentCiphertext[](0),
                ownerField: bytes32(0),
                publicOutputs: new CommitmentPreimage[](0)
            }),
            unshieldPreimage: CommitmentPreimage({
                npk: bytes32(uint256(uint160(address(adjudicator)))),
                token: TokenData({tokenType: TokenType.ERC20, tokenAddress: address(token), tokenSubID: 0}),
                value: 1
            })
        });

        adjudicator.setHoldingsLock(channelId, 1);
        uint256 hBefore = adjudicator.heldValue(address(token), channelId);
        vm.expectRevert(bytes(GUARD_REVERT));
        adjudicator.depositFromNote(channelId, 0, txs);
        uint256 hAfter = adjudicator.heldValue(address(token), channelId);
        console.log("ARN521_C2 depositFromNote", hBefore, hAfter);

        assertEq(adjudicator.heldValue(address(token), channelId), 0);
    }

    function test_guard_transfer_revertsWhileInProgress() public {
        bytes32 channelId = bytes32(uint256(3));
        Outcome.Allocation[] memory allocations = new Outcome.Allocation[](1);
        allocations[0] = Outcome.Allocation(
            bytes32(uint256(uint160(address(0xBEEF)))),
            1,
            uint8(Outcome.AllocationType.simple),
            ''
        );
        Outcome.SingleAssetExit[] memory outcome = new Outcome.SingleAssetExit[](1);
        outcome[0] = Outcome.SingleAssetExit(
            ASSET,
            Outcome.AssetMetadata(Outcome.AssetType.Default, ''),
            allocations
        );
        bytes memory outcomeBytes = abi.encode(outcome);
        bytes32 stateHash = keccak256('guard transfer state');
        adjudicator.finalize(channelId, stateHash, outcomeBytes);
        adjudicator.setHoldingsLock(channelId, 1);
        uint256 hBefore = adjudicator.heldValue(ASSET, channelId);

        vm.expectRevert(bytes(GUARD_REVERT));
        adjudicator.transfer(0, channelId, outcomeBytes, stateHash, new uint256[](0));
        uint256 hAfter = adjudicator.heldValue(ASSET, channelId);
        console.log("ARN521_C2 transfer", hBefore, hAfter);

        assertEq(adjudicator.heldValue(ASSET, channelId), 0);
    }

    function test_guard_transferAllAssets_revertsWhileInProgress() public {
        bytes32 channelId = bytes32(uint256(4));
        adjudicator.setHoldingsLock(channelId, 1);
        uint256 hBefore = adjudicator.heldValue(ASSET, channelId);

        vm.expectRevert(bytes(GUARD_REVERT));
        adjudicator.transferAllAssets(channelId, new Outcome.SingleAssetExit[](0), bytes32(0));
        uint256 hAfter = adjudicator.heldValue(ASSET, channelId);
        console.log("ARN521_C2 transferAllAssets", hBefore, hAfter);

        assertEq(adjudicator.heldValue(ASSET, channelId), 0);
    }

    function test_guard_concludeAndTransferAllAssets_revertsWhileInProgress() public {
        uint256 key = 0xC0FFEE;
        address[] memory participants = new address[](1);
        participants[0] = vm.addr(key);
        FixedPart memory fixedPart = FixedPart({
            participants: participants,
            channelNonce: 42,
            appDefinition: address(0),
            challengeDuration: 1 days
        });
        VariablePart memory variablePart = VariablePart({
            outcome: new Outcome.SingleAssetExit[](0),
            appData: '',
            turnNum: 1,
            isFinal: true
        });
        Signature[] memory sigs = new Signature[](1);
        sigs[0] = ChannelStates.sign(key, fixedPart, variablePart);
        SignedVariablePart memory candidate = SignedVariablePart({
            variablePart: variablePart,
            sigs: sigs
        });

        bytes32 channelId = NitroUtils.getChannelId(fixedPart);
        adjudicator.setHoldingsLock(channelId, 1);
        uint256 hBefore = adjudicator.heldValue(ASSET, channelId);

        vm.expectRevert(bytes(GUARD_REVERT));
        adjudicator.concludeAndTransferAllAssets(fixedPart, candidate);
        uint256 hAfter =adjudicator.heldValue(ASSET, channelId);
        console.log("ARN521_C2 concludeAndTransferAllAssets", hBefore, hAfter);

        // The whole call reverted atomically: `_conclude`'s effects are rolled back too.
        (, uint48 finalizesAt, ) = adjudicator.unpackStatus(channelId);
        assertEq(finalizesAt, 0, 'channel must remain unfinalized after the reverted attempt');
    }

    function test_guard_reclaim_revertsWhileInProgress() public {
        bytes32 sourceChannelId = bytes32(uint256(5));
        bytes32 targetChannelId = bytes32(uint256(6));

        bytes memory sourceOutcomeBytes = _reclaimSourceOutcomeBytes(targetChannelId);
        bytes memory targetOutcomeBytes = _reclaimTargetOutcomeBytes();

        FixedPart memory fixedPart;
        VariablePart memory variablePart = _reclaimVariablePart();
        bytes32 sourceStateHash = NitroUtils.hashState(fixedPart, variablePart);
        bytes32 targetStateHash = keccak256('guard reclaim target state');

        adjudicator.finalize(sourceChannelId, sourceStateHash, sourceOutcomeBytes);
        adjudicator.finalize(targetChannelId, targetStateHash, targetOutcomeBytes);

        IMultiAssetHolder.ReclaimArgs memory args = IMultiAssetHolder.ReclaimArgs({
            sourceChannelId: sourceChannelId,
            fixedPart: fixedPart,
            variablePart: variablePart,
            sourceOutcomeBytes: sourceOutcomeBytes,
            sourceAssetIndex: 0,
            indexOfTargetInSource: 0,
            targetStateHash: targetStateHash,
            targetOutcomeBytes: targetOutcomeBytes,
            targetAssetIndex: 0
        });

        adjudicator.setHoldingsLock(sourceChannelId, 1);
        uint256 hBefore = adjudicator.heldValue(ASSET, sourceChannelId);
        vm.expectRevert(bytes(GUARD_REVERT));
        adjudicator.reclaim(args);
        uint256 hAfter = adjudicator.heldValue(ASSET, sourceChannelId);
        console.log("ARN521_C2 reclaim", hBefore, hAfter);

        assertEq(adjudicator.heldValue(ASSET, sourceChannelId), 0);
    }

    function _reclaimVariablePart() internal pure returns (VariablePart memory) {
        return
            VariablePart({
                outcome: new Outcome.SingleAssetExit[](0),
                appData: '',
                turnNum: 0,
                isFinal: true
            });
    }

    function _reclaimSourceOutcomeBytes(bytes32 targetChannelId) internal pure returns (bytes memory) {
        Outcome.Allocation[] memory sourceAllocations = new Outcome.Allocation[](1);
        sourceAllocations[0] = Outcome.Allocation(
            targetChannelId,
            10,
            uint8(Outcome.AllocationType.guarantee),
            abi.encode(bytes32(uint256(1)), bytes32(uint256(2)))
        );
        Outcome.SingleAssetExit[] memory sourceOutcome = new Outcome.SingleAssetExit[](1);
        sourceOutcome[0] = Outcome.SingleAssetExit(
            ASSET,
            Outcome.AssetMetadata(Outcome.AssetType.Default, ''),
            sourceAllocations
        );
        return abi.encode(sourceOutcome);
    }

    function _reclaimTargetOutcomeBytes() internal pure returns ( bytes memory) {
        Outcome.Allocation[] memory targetAllocations = new Outcome.Allocation[](2);
        targetAllocations[0] = Outcome.Allocation(
            bytes32(uint256(1)),
            5,
            uint8(Outcome.AllocationType.simple),
            ''
        );
        targetAllocations[1] = Outcome.Allocation(
            bytes32(uint256(2)),
            5,
            uint8(Outcome.AllocationType.simple),
            ''
        );
        Outcome.SingleAssetExit[] memory targetOutcome = new Outcome.SingleAssetExit[](1);
        targetOutcome[0] = Outcome.SingleAssetExit(
            ASSET,
            Outcome.AssetMetadata(Outcome.AssetType.Default, ''),
            targetAllocations
        );
        return abi.encode(targetOutcome);
    }
}
