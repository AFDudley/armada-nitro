// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test, Vm} from 'forge-std/Test.sol';
import {console} from 'forge-std/console.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {MockUSDCV2} from 'armada/cctp/MockUSDCV2.sol';
import {ArmadaFixture} from './helpers/ArmadaFixture.sol';

/// @dev A hooked ERC20 token: on `transferFrom` (invoked by `SafeERC20.safeTransferFrom`) it
/// calls back into the adjudicator's `deposit` on the same channel; the guard must reject it.
contract HookedToken {
    ArmadaNitroAdjudicator internal adjudicator;
    bytes32 internal channelId;
    uint256 internal amount;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public nestedCallReverted;

    function setValues(
        ArmadaNitroAdjudicator adj,
        bytes32 cid,
        uint256 amt
    ) external {
        adjudicator = adj;
        channelId = cid;
        amount = amt;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external {
        allowance[msg.sender][spender] = amt;
    }

    // `SafeERC20.safeTransferFrom` (used by `deposit`) calls this real ERC20 `transferFrom`
    // selector on the token; the hook therefore lives here, not in a `safeTransferFrom` method.
    function transferFrom(address from, address to, uint256 amt) external {
        require(allowance[from][msg.sender] >= amt, 'insufficient allowance');
        // Nested call into the adjudicator on the same channel: must revert due to the guard.
        (bool ok, ) = address(adjudicator).call(
            abi.encodeCall(adjudicator.deposit, (address(this), channelId, 0, amt))
        );
        nestedCallReverted = !ok;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        allowance[from][msg.sender] -= amt;
    }

    function transfer(address to, uint256 amt) external {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
    }
}

contract ReentryDepositTest is ArmadaFixture {
    ArmadaNitroAdjudicator internal adjudicator;
    uint256 internal constant AMOUNT = 100e6;

    function setUp() public {
        _deployArmada();
        adjudicator = new ArmadaNitroAdjudicator(pool);
    }

    /// c1 (hooked-deposit-matches-plain-deposit): a plain deposit and a hooked deposit from
    /// identical starting conditions end with identical recorded holdings, and the hooked
    /// token's own nested call to the adjudicator reverts.
    function test_plainAndHookedDepositsEndWithIdenticalHoldings() public {
        // Baseline: a plain ERC20 (USDC) deposit on channel 1.
        MockUSDCV2 plainToken = new MockUSDCV2('Plain USDC', 'pUSDC');
        bytes32 plainChannelId = keccak256('plain deposit channel');
        plainToken.mint(address(this), AMOUNT);
        vm.startPrank(address(this));
        plainToken.approve(address(adjudicator), AMOUNT);
        adjudicator.deposit(address(plainToken), plainChannelId, 0, AMOUNT);
        uint256 plainHoldings = adjudicator.holdings(address(plainToken), plainChannelId);
        vm.stopPrank();

        // Hooked deposit: a hooked token whose transfer hook calls back into the adjudicator.
        HookedToken hooked = new HookedToken();
        bytes32 hookedChannelId = keccak256('hooked deposit channel');
        hooked.setValues(adjudicator, hookedChannelId, AMOUNT);
        hooked.mint(address(this), AMOUNT);
        vm.startPrank(address(this));
        hooked.approve(address(adjudicator), AMOUNT);
        adjudicator.deposit(address(hooked), hookedChannelId, 0, AMOUNT);
        uint256 hookedHoldings = adjudicator.holdings(address(hooked), hookedChannelId);
        vm.stopPrank();

        // Emit the observed final holdings so the acceptance script can compute the no-arbitrage
        // flows: a re-entering hook leaving final holdings unchanged means plain == hooked.
        console.log("ARN521_C1", plainHoldings, hookedHoldings);

        // Both deposits end with the same recorded holdings...
        assertEq(plainHoldings, AMOUNT);
        assertEq(hookedHoldings, AMOUNT);
        assertEq(plainHoldings, hookedHoldings, 'plain and hooked must match');
        // ...and the hooked token's own nested call to the adjudicator reverted.
        assertTrue(hooked.nestedCallReverted(), 'hooked token call did not revert');
    }
}
