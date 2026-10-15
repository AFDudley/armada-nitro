// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test, Vm} from 'forge-std/Test.sol';
import {console} from 'forge-std/console.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {MockUSDCV2} from 'armada/cctp/MockUSDCV2.sol';
import {ArmadaFixture} from './helpers/ArmadaFixture.sol';

/// @dev A hooked ERC20 token: on `transferFrom` (invoked by `SafeERC20.safeTransferFrom`) it
/// calls back into the adjudicator's `deposit` on the same channel; the per-channel lock guard
/// must reject the nested call.
contract HookedToken {
    ArmadaNitroAdjudicator internal adjudicator;
    bytes32 internal channelId;
    uint256 internal amount;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public nestedCallReverted;
    bytes public nestedCallRevertData;

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
        // Nested call into the adjudicator on the same channel: the per-channel lock guard must
        // refuse it. Capture the guard's revert data so the test can check it is the guard's own
        // message, not some other reason the nested call happens to fail for.
        (bool ok, bytes memory ret) = address(adjudicator).call(
            abi.encodeCall(adjudicator.deposit, (address(this), channelId, 0, amt))
        );
        nestedCallReverted = !ok;
        if (!ok) {
            nestedCallRevertData = ret;
        }
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
    string internal constant GUARD_MSG = 'Re-entered while in progress';

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
    /// identical starting conditions end with identical recorded holdings, and the hooked
    /// token's own nested call to the adjudicator reverts.
    ///
    /// c2 (test-detects-missing-guard): the nested deposit must revert with the guard's own
    /// 'Re-entered while in progress' message, not merely revert for some other reason. On
    /// 32ad5e5^ (holdingsLock absent) the nested deposit's underlying `transferFrom` reverts with
    /// 'insufficient allowance' instead, so this test fails there — proving it is a real detector
    /// of the guard, not a test that passes regardless of whether the guard exists.
    function test_plainAndHookedDepositsEndWithIdenticalHoldings() public {
        // Baseline: a plain ERC20 (USDC) deposit on a fresh channel.
        bytes32 plainChannelId = keccak256('plain deposit channel');
        plainToken.mint(address(this), AMOUNT);
        vm.startPrank(address(this));
        plainToken.approve(address(adjudicator), AMOUNT);
        adjudicator.deposit(address(plainToken), plainChannelId, 0, AMOUNT);
        uint256 plainHoldings = adjudicator.holdings(address(plainToken), plainChannelId);
        vm.stopPrank();

        // Hooked deposit: the hooked token's transfer hook calls back into the adjudicator.
        bytes32 hookedChannelId = keccak256('hooked deposit channel');
        hookedToken.setValues(adjudicator, hookedChannelId, AMOUNT);
        hookedToken.mint(address(this), AMOUNT);
        vm.startPrank(address(this));
        hookedToken.approve(address(adjudicator), AMOUNT);
        adjudicator.deposit(address(hookedToken), hookedChannelId, 0, AMOUNT);
        uint256 hookedHoldings = adjudicator.holdings(address(hookedToken), hookedChannelId);
        vm.stopPrank();

        // Emit the observed final holdings so the c1 acceptance script can compute the
        // no-arbitrage flows: a re-entering hook leaving final holdings unchanged means
        // plain == hooked.
        console.log("ARN521_C1", plainHoldings, hookedHoldings);

        // c1: both deposits end with the same recorded holdings; no value is lost or duplicated
        // by the attempted re-entry.
        assertEq(plainHoldings, AMOUNT);
        assertEq(hookedHoldings, AMOUNT);
        assertEq(plainHoldings, hookedHoldings, 'plain and hooked must match');
        // c2: the nested call must have reverted, and specifically with the guard's own message.
        assertTrue(hookedToken.nestedCallReverted(), 'hooked token call did not revert');
        assertEq(
            this._decodeRevertMessage(hookedToken.nestedCallRevertData()),
            GUARD_MSG,
            'nested deposit must revert with the guard message'
        );
    }

    /// @dev Decode an `Error(string)` revert payload's message. `rd` layout: 4-byte selector +
    /// standard ABI encoding of a single `string` (32-byte offset word, 32-byte length word,
    /// padded data). Declared `external`+`calldata` (and called via `this.`) solely so the
    /// 4-byte selector can be sliced off with calldata's `[4:]` range syntax, which memory bytes
    /// do not support in this compiler version.
    function _decodeRevertMessage(bytes calldata rd) external pure returns (string memory) {
        require(rd.length >= 4, 'revert data too short to carry a selector');
        (string memory message) = abi.decode(rd[4:], (string));
        return message;
    }
}
