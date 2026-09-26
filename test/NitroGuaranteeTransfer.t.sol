// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test} from 'forge-std/Test.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';
import {NitroAdjudicator} from 'src/nitro/NitroAdjudicator.sol';

/// Finalizes channels and sets holdings directly, so `transfer` can be exercised without
/// running a challenge.
contract FinalizedChannelHarness is NitroAdjudicator {
    function finalize(bytes32 channelId, bytes32 stateHash, bytes memory outcomeBytes) external {
        statusOf[channelId] = _generateStatus(
            ChannelData(0, uint48(block.timestamp), stateHash, keccak256(outcomeBytes))
        );
    }

    function setHoldings(address asset, bytes32 channelId, uint256 amount) external {
        holdings[asset][channelId] = amount;
    }
}

/// `transfer` must never pay out a guarantee allocation (only `reclaim` may consume one), and
/// must pay simple allocations wherever they sit relative to a guarantee. Both properties must
/// hold when `indices` selects a subset of the allocations.
contract NitroGuaranteeTransferTest is Test {
    FinalizedChannelHarness internal adjudicator;

    address internal constant ETH = address(0);
    bytes32 internal constant LEDGER = keccak256('ledger channel');
    bytes32 internal constant VIRTUAL = keccak256('virtual channel');
    bytes32 internal constant STATE_HASH = keccak256('final state');
    address internal alice = makeAddr('alice');
    address internal hub = makeAddr('hub');

    function setUp() public {
        adjudicator = new FinalizedChannelHarness();
        vm.warp(1_000);
    }

    function test_transfer_revertsWhenIndicesSelectGuaranteeAfterSkippedSimple() public {
        Outcome.Allocation[] memory allocations = new Outcome.Allocation[](3);
        allocations[0] = _simple(alice, 5);
        allocations[1] = _simple(hub, 5);
        allocations[2] = _guarantee(VIRTUAL, 10);
        bytes memory outcomeBytes = _finalizeFunded(allocations, 20);

        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 2;

        vm.expectRevert('cannot transfer a guarantee');
        adjudicator.transfer(0, LEDGER, outcomeBytes, STATE_HASH, indices);
    }

    function test_transfer_paysSimpleAllocationListedAfterGuarantee() public {
        Outcome.Allocation[] memory allocations = new Outcome.Allocation[](2);
        allocations[0] = _guarantee(VIRTUAL, 10);
        allocations[1] = _simple(alice, 5);
        bytes memory outcomeBytes = _finalizeFunded(allocations, 15);

        uint256[] memory indices = new uint256[](1);
        indices[0] = 1;

        adjudicator.transfer(0, LEDGER, outcomeBytes, STATE_HASH, indices);

        assertEq(alice.balance, 5);
        assertEq(adjudicator.holdings(ETH, LEDGER), 10);
        assertEq(adjudicator.holdings(ETH, VIRTUAL), 0);
    }

    function _finalizeFunded(
        Outcome.Allocation[] memory allocations,
        uint256 funding
    ) internal returns (bytes memory outcomeBytes) {
        Outcome.SingleAssetExit[] memory outcome = new Outcome.SingleAssetExit[](1);
        outcome[0] = Outcome.SingleAssetExit(
            ETH,
            Outcome.AssetMetadata(Outcome.AssetType.Default, ''),
            allocations
        );
        outcomeBytes = abi.encode(outcome);
        adjudicator.finalize(LEDGER, STATE_HASH, outcomeBytes);
        adjudicator.setHoldings(ETH, LEDGER, funding);
        vm.deal(address(adjudicator), funding);
    }

    function _simple(address to, uint256 amount) internal pure returns (Outcome.Allocation memory) {
        return
            Outcome.Allocation(
                bytes32(uint256(uint160(to))),
                amount,
                uint8(Outcome.AllocationType.simple),
                ''
            );
    }

    function _guarantee(
        bytes32 target,
        uint256 amount
    ) internal view returns (Outcome.Allocation memory) {
        return
            Outcome.Allocation(
                target,
                amount,
                uint8(Outcome.AllocationType.guarantee),
                abi.encode(bytes32(uint256(uint160(alice))), bytes32(uint256(uint160(hub))))
            );
    }
}
