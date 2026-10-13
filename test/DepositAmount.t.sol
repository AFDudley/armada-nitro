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

/// @dev Minimal ERC20 that delivers exactly the requested amount.
contract NormalToken {
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
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract DepositAmountTest is ArmadaFixture {
    ArmadaNitroAdjudicator adjudicator;
    ShortToken internal shortToken;
    NormalToken internal normalToken;

    function setUp() public {
        _deployArmada();
        // arn-3d8: the test tokens must be on the adjudicator's configured asset list.
        shortToken = new ShortToken();
        normalToken = new NormalToken();
        address[] memory assets = new address[](6);
        assets[0] = address(usdc);
        assets[1] = address(0x0000000000000000000000000000000000000001); // WETH
        assets[2] = address(0x0000000000000000000000000000000000000002); // wstETH
        assets[3] = address(0x0000000000000000000000000000000000000003); // waUSDC
        assets[4] = address(shortToken);
        assets[5] = address(normalToken);
        adjudicator = new ArmadaNitroAdjudicator(pool, assets);
    }

    /// @dev c1: a token that pays one unit less than requested must revert the deposit.
    function test_shortTransfer_depositReverts() public {
        uint256 amount = 10;
        shortToken.mint(address(this), 100);
        shortToken.approve(address(adjudicator), amount);
        bytes32 channelId = keccak256("channel-arn-0cf");

        vm.expectRevert('Deposit amount mismatch');
        adjudicator.deposit(address(shortToken), channelId, 0, amount);
    }

    /// @dev c2: a normal token that pays the full amount leaves the holdings increase equal to the
    /// adjudicator's measured token balance increase.
    function test_normalDeposit_holdingsDeltaEqualsBalanceDelta() public {
        uint256 amount = 50;
        normalToken.mint(address(this), amount);
        normalToken.approve(address(adjudicator), amount);
        bytes32 channelId = keccak256("channel-arn-0cf");

        uint256 heldBefore = adjudicator.holdings(address(normalToken), channelId);
        uint256 balBefore = normalToken.balanceOf(address(adjudicator));
        adjudicator.deposit(address(normalToken), channelId, heldBefore, amount);
        uint256 heldDelta = adjudicator.holdings(address(normalToken), channelId) - heldBefore;
        uint256 balDelta = normalToken.balanceOf(address(adjudicator)) - balBefore;

        assertEq(heldDelta, balDelta, 'holdings delta != balance delta');
    }
}
