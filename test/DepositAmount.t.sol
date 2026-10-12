// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test, Vm} from 'forge-std/Test.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {ArmadaFixture} from './helpers/ArmadaFixture.sol';

/// @dev Minimal ERC20 that delivers one unit less than the requested `transferFrom` amount.
contract ShortToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[address(this)][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (balanceOf[from] < amount) return false;
        // deliver exactly one unit less than requested.
        balanceOf[from] -= amount - 1;
        balanceOf[to] += amount - 1;
        return true;
    }
}

contract DepositAmountTest is ArmadaFixture {
    ArmadaNitroAdjudicator adjudicator;

    function setUp() public {
        _deployArmada();
        adjudicator = new ArmadaNitroAdjudicator(pool);
    }

    /// @dev c1: a token that pays one unit less than requested must revert the deposit.
    function test_shortTransfer_depositReverts() public {
        ShortToken token = new ShortToken();
        uint256 amount = 10;
        token.mint(address(this), 100);
        token.approve(address(adjudicator), amount);
        bytes32 channelId = keccak256("channel-arn-0cf");

        vm.expectRevert('Deposit amount mismatch');
        adjudicator.deposit(address(token), channelId, 0, amount);
    }

    /// @dev c2: a normal token that pays the full amount leaves the holdings increase equal to the
    /// adjudicator's measured token balance increase.
    function test_normalDeposit_holdingsDeltaEqualsBalanceDelta() public {
        uint256 amount = 50;
        usdc.mint(address(this), amount);
        usdc.approve(address(adjudicator), amount);
        bytes32 channelId = keccak256("channel-arn-0cf");

        uint256 heldBefore = adjudicator.holdings(address(usdc), channelId);
        uint256 balBefore = usdc.balanceOf(address(adjudicator));
        adjudicator.deposit(address(usdc), channelId, heldBefore, amount);
        uint256 heldDelta = adjudicator.holdings(address(usdc), channelId) - heldBefore;
        uint256 balDelta = usdc.balanceOf(address(adjudicator)) - balBefore;

        assertEq(heldDelta, balDelta, 'holdings delta != balance delta');
    }
}
