// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test} from 'forge-std/Test.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';
import {NitroAdjudicator} from 'src/nitro/NitroAdjudicator.sol';

/// @dev Finalizes channels and sets holdings directly, so a payout can be exercised without
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

/// @dev Test ERC20 whose transfer reports failure (returns false) and moves nothing.
contract ReturnsFalseToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        return false;
    }
}

/// @dev Standard test ERC20 whose transfer reports success (returns true) and moves the full amount.
contract ReturnsTrueToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev USDT-like test ERC20 whose transfer returns no value (void), moving the full amount.
contract ReturnsNothingToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
    function transfer(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

/// Common surface for the test tokens, so the conservation law can be checked uniformly.
interface IConservationToken {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
}

contract PayoutConservationTest is Test {
    FinalizedChannelHarness internal adjudicator;
    bytes32 internal constant CHANNEL = keccak256("payout channel");
    bytes32 internal constant STATE_HASH = keccak256("payout state");
    address internal constant DEST = 0x1234567890AbcdEF1234567890aBcdef12345678; // fixed external destination
    uint256 internal constant AMOUNT = 100;

    function setUp() public {
        adjudicator = new FinalizedChannelHarness();
    }

    /// @dev c1: a token whose transfer reports failure MUST revert the payout as a whole, so value is conserved.
    function test_returnsFalse() public {
        ReturnsFalseToken token = new ReturnsFalseToken();
        _runConservation(address(token), IConservationToken(address(token)), false);
    }

    /// @dev c2a: a standard token (returns true) pays the full amount to the destination; value is conserved.
    function test_returnsTrue() public {
        ReturnsTrueToken token = new ReturnsTrueToken();
        _runConservation(address(token), IConservationToken(address(token)), true);
    }

    /// @dev c2b: a USDT-like token (returns no value) pays the full amount to the destination; value is conserved.
    function test_returnsNothing() public {
        ReturnsNothingToken token = new ReturnsNothingToken();
        _runConservation(address(token), IConservationToken(address(token)), true);
    }

    /// @dev A simple allocation paying `amount` of the asset to an external `to` address.
    function _simpleAlloc(address to, uint256 amount) internal pure returns (Outcome.Allocation memory) {
        return
            Outcome.Allocation(
                bytes32(uint256(uint160(to))),
                amount,
                uint8(Outcome.AllocationType.simple),
                ''
            );
    }

    /// @dev Funds a channel with the token, pays it out to an external destination, and verifies
    /// conservation: the total of channel holdings plus the destination balance is unchanged.
    function _runConservation(address token, IConservationToken tok, bool paysOut) internal {
        Outcome.Allocation[] memory allocations = new Outcome.Allocation[](1);
        allocations[0] = _simpleAlloc(DEST, AMOUNT);
        Outcome.SingleAssetExit[] memory outcome = new Outcome.SingleAssetExit[](1);
        outcome[0] = Outcome.SingleAssetExit(
            token,
            Outcome.AssetMetadata(Outcome.AssetType.Default, ''),
            allocations
        );
        bytes memory outcomeBytes = abi.encode(outcome);
        adjudicator.finalize(CHANNEL, STATE_HASH, outcomeBytes);
        tok.mint(address(adjudicator), AMOUNT);
        adjudicator.setHoldings(token, CHANNEL, AMOUNT);

        uint256 holdingsBefore = adjudicator.holdings(token, CHANNEL);
        uint256 destBefore = tok.balanceOf(DEST);
        uint256 totalBefore = holdingsBefore + destBefore;

        if (paysOut) {
            adjudicator.transferAllAssets(CHANNEL, outcome, STATE_HASH);
        } else {
            // c1: the payout is refused as a whole (the token reports failure).
            vm.expectRevert("SafeERC20: ERC20 operation did not succeed");
            adjudicator.transferAllAssets(CHANNEL, outcome, STATE_HASH);
        }

        uint256 holdingsAfter = adjudicator.holdings(token, CHANNEL);
        uint256 destAfter = tok.balanceOf(DEST);
        uint256 totalAfter = holdingsAfter + destAfter;

        // Conservation law: value in the channel plus the destination balance is invariant.
        assertEq(totalBefore, totalAfter, "value not conserved");

        if (paysOut) {
            assertEq(destAfter, AMOUNT, "destination did not receive the full amount");
            assertEq(holdingsAfter, holdingsBefore - AMOUNT, "holdings did not drop by the full amount");
        } else {
            assertEq(destAfter, 0, "destination should receive nothing");
            assertEq(holdingsAfter, holdingsBefore, "channel holdings should be unchanged");
        }
    }
}
