// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @dev A minimal ERC20 whose owner can force every `transfer`/`transferFrom` to revert.
 * Used only by scripts/check-watchtower-respond-per-asset.py (arn-765) to drive the exact same
 * two-asset channel setup through two runs of script/WatchtowerScenario.s.sol's `respond`: one
 * where this (second) asset's payout succeeds, one where it reverts -- isolating the payout
 * step's behavior from everything else (funding, signatures, turn numbers) which stays identical.
 */
contract ToggleableERC20 is IERC20 {
    address public immutable owner;
    bool public rejectTransfers;

    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    constructor() {
        owner = msg.sender;
    }

    function setRejectTransfers(bool reject) external {
        require(msg.sender == owner, 'not owner');
        rejectTransfers = reject;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, 'not owner');
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(!rejectTransfers, 'ToggleableERC20: transfers rejected');
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        require(!rejectTransfers, 'ToggleableERC20: transfers rejected');
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, 'ToggleableERC20: insufficient allowance');
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, 'ToggleableERC20: insufficient balance');
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
