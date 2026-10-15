// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test, Vm} from 'forge-std/Test.sol';
import {console} from 'forge-std/console.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {MockUSDCV2} from 'armada/cctp/MockUSDCV2.sol';
import {ArmadaFixture} from './helpers/ArmadaFixture.sol';

/// @dev A hooked ERC20 token: on `transferFrom` (invoked by `SafeERC20.safeTransferFrom`) it
/// calls back into the adjudicator's `deposit` on the same channel, depositing a second,
/// allow-listed token (`otherToken`) that it holds and has approved. Without a guard that nested
/// deposit succeeds, so the per-channel lock guard is the only thing that makes it revert.
contract HookedToken {
    ArmadaNitroAdjudicator internal adjudicator;
    MockUSDCV2 internal otherToken;
    bytes32 internal channelId;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public nestedCallReverted;
    bytes public nestedRevertData;

    function setValues(ArmadaNitroAdjudicator adj, MockUSDCV2 other, bytes32 cid, uint256 amt) external {
        adjudicator = adj;
        otherToken = other;
        channelId = cid;
        otherToken.approve(address(adj), amt);
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
        // Nested deposit of `otherToken` into the same channel, while the outer deposit runs.
        (bool ok, bytes memory data) = address(adjudicator).call(
            abi.encodeCall(adjudicator.deposit, (address(otherToken), channelId, 0, amt))
        );
        nestedCallReverted = !ok;
        nestedRevertData = data;
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
    MockUSDCV2 internal plainToken;
    HookedToken internal hookedToken;
    uint256 internal constant AMOUNT = 100e6;

    function setUp() public {
        _deployArmada();
        plainToken = new MockUSDCV2('Plain USDC', 'pUSDC');
        hookedToken = new HookedToken();
        address[] memory assets = new address[](2);
        assets[0] = address(plainToken);
        assets[1] = address(hookedToken);
        adjudicator = new ArmadaNitroAdjudicator(pool, assets);
    }

    /// c1 (hooked-deposit-matches-plain-deposit): a plain deposit and a hooked deposit from
    /// identical starting conditions end with identical recorded holdings. The hook's nested
    /// deposit on the same channel reverts with the guard's reason and credits nothing.
    function test_plainAndHookedDepositsEndWithIdenticalHoldings() public {
        // Baseline: a plain ERC20 (USDC) deposit on a fresh channel.
        bytes32 plainChannelId = keccak256('plain deposit channel');
        plainToken.mint(address(this), AMOUNT);
        vm.startPrank(address(this));
        plainToken.approve(address(adjudicator), AMOUNT);
        adjudicator.deposit(address(plainToken), plainChannelId, 0, AMOUNT);
        uint256 plainHoldings = adjudicator.holdings(address(plainToken), plainChannelId);
        vm.stopPrank();

        // Hooked deposit: the hooked token's transfer hook deposits plainToken into the same
        // channel through the adjudicator.
        bytes32 hookedChannelId = keccak256('hooked deposit channel');
        plainToken.mint(address(hookedToken), AMOUNT);
        hookedToken.setValues(adjudicator, plainToken, hookedChannelId, AMOUNT);
        hookedToken.mint(address(this), AMOUNT);
        vm.startPrank(address(this));
        hookedToken.approve(address(adjudicator), AMOUNT);
        adjudicator.deposit(address(hookedToken), hookedChannelId, 0, AMOUNT);
        uint256 hookedHoldings = adjudicator.holdings(address(hookedToken), hookedChannelId);
        vm.stopPrank();

        // Emit the observed final holdings so the acceptance script can compute the no-arbitrage
        // flows: a re-entering hook leaving final holdings unchanged means plain == hooked.
        console.log("ARN521_C1", plainHoldings, hookedHoldings);

        // Both deposits end with the same recorded holdings...
        assertEq(plainHoldings, AMOUNT);
        assertEq(hookedHoldings, AMOUNT);
        assertEq(plainHoldings, hookedHoldings, 'plain and hooked must match');
        // ...the nested deposit reverted with the guard's reason...
        assertTrue(hookedToken.nestedCallReverted(), 'nested deposit did not revert');
        assertEq(
            hookedToken.nestedRevertData(),
            abi.encodeWithSignature('Error(string)', 'Re-entered while in progress'),
            'nested deposit reverted for a reason other than the guard'
        );
        // ...and it credited nothing to the channel.
        assertEq(adjudicator.holdings(address(plainToken), hookedChannelId), 0);
        assertEq(plainToken.balanceOf(address(hookedToken)), AMOUNT);
    }
}
