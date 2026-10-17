// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';
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
    function transfer(address, uint256) external pure returns (bool) {
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
        balanceOf[msg.sender] -= amount;
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
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/// Common surface for the test tokens, so the conservation law can be checked uniformly.
interface IConservationToken {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
}

/// @dev Exercises MultiAssetHolder._transferAsset through the adjudicator and MEASURES the
/// signed change of the channel holdings and the destination balance. Each test emits its
/// measured deltas as console log lines (`<label>_hdelta=`, `<label>_ddelta=`,
/// `<label>_requested=`) BEFORE any assertion, so the measurement is captured even when the
/// branch-correct assertion fails on the buggy base tree. scripts/check-adjudicator-payout-
/// conservation.py reads those lines and builds the `flows` the conservation oracle grades.
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
        _exercise(address(token), IConservationToken(address(token)), "returnsFalse", false);
    }

    /// @dev c2a: a standard token (returns true) pays the full amount to the destination; value is conserved.
    function test_returnsTrue() public {
        ReturnsTrueToken token = new ReturnsTrueToken();
        _exercise(address(token), IConservationToken(address(token)), "returnsTrue", true);
    }

    /// @dev c2b: a USDT-like token (returns no value) pays the full amount to the destination; value is conserved.
    function test_returnsNothing() public {
        ReturnsNothingToken token = new ReturnsNothingToken();
        _exercise(address(token), IConservationToken(address(token)), "returnsNothing", true);
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

    /// @dev Funds a channel with the token, attempts to pay it out to an external destination, and
    /// measures the signed deltas of the channel holdings and the destination balance. The payout
    /// call is wrapped in try/catch so the measurement and the log lines always run, whether the
    /// payout succeeds or reverts. The branch-correct assertions follow the log lines.
    function _exercise(
        address token,
        IConservationToken tok,
        string memory label,
        bool expectPayout
    ) internal {
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

        int256 hBefore = int256(adjudicator.holdings(token, CHANNEL));
        int256 dBefore = int256(tok.balanceOf(DEST));

        bool reverted;
        try adjudicator.transferAllAssets(CHANNEL, outcome, STATE_HASH) {
            reverted = false;
        } catch {
            reverted = true;
        }

        int256 hDelta = int256(adjudicator.holdings(token, CHANNEL)) - hBefore;
        int256 dDelta = int256(tok.balanceOf(DEST)) - dBefore;

        // Measurement — emitted BEFORE the assertions, so the base tree's buggy run still
        // reports its deltas even though an assertion below reverts the test.
        console2.log(string.concat(label, "_hdelta=", vm.toString(hDelta)));
        console2.log(string.concat(label, "_ddelta=", vm.toString(dDelta)));
        console2.log(string.concat(label, "_requested=", vm.toString(int256(AMOUNT))));

        // Branch-correct behavior, asserted for the pre-commit forge-test gate.
        if (expectPayout) {
            assertFalse(reverted, "payout should succeed");
            assertEq(dDelta, int256(AMOUNT), "destination did not receive the full amount");
            assertEq(hDelta, -int256(AMOUNT), "holdings did not drop by the full amount");
        } else {
            assertTrue(reverted, "payout should be refused as a whole");
            assertEq(dDelta, int256(0), "destination should receive nothing");
            assertEq(hDelta, int256(0), "channel holdings should be unchanged");
        }
    }
}
