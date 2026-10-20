// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ArmadaFixture} from './helpers/ArmadaFixture.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {MockUSDCV2} from 'armada/cctp/MockUSDCV2.sol';
import {ArmadaNotes} from './helpers/ArmadaNotes.sol';
import {IArmadaPool, Transaction} from 'src/armada/IArmadaPool.sol';

/// @dev arn-3d8: two deposits differ ONLY in the token's configured status (metamorphic,
/// monotonicity). A listed-token deposit credits the channel; an unlisted-token deposit reverts
/// with 'Asset not configured'. The relation must hold through BOTH the plain deposit and the
/// note-based deposit.
contract AdjudicatorAssetListTest is ArmadaFixture {
    MockUSDCV2 internal unlisted;
    ArmadaNitroAdjudicator internal adjudicator;
    address internal user = address(uint160(0xA11CE));
    address internal broadcaster = address(uint160(0xB0CA));
    uint256 internal nullifierSeed;

    function setUp() public {
        _deployArmada();
        // Unlisted token: a second USDC mock NOT on the configured list.
        unlisted = new MockUSDCV2('UnlistedToken', 'UNL');

        // The fixturenet configured list: USDC, WETH, wstETH, waUSDC.
        address[] memory assets = new address[](4);
        assets[0] = address(usdc);
        assets[1] = address(0x0000000000000000000000000000000000000001);  // WETH
        assets[2] = address(0x0000000000000000000000000000000000000002);  // wstETH
        assets[3] = address(0x0000000000000000000000000000000000000003);  // waUSDC
        adjudicator = new ArmadaNitroAdjudicator(pool, assets);
    }

    // c2: depositFromNote entry point (N1a: the base `deposit` entry point is gone -- a channel
    // is funded only through depositFromNote, which carries a proof)
    function test_depositFromNote_metamorphic_listedCreditsUnlistedReverts() public {
        bytes32 channelId = keccak256('arn-3d8-c2');
        uint256 value = 100e6;
        bytes32 npk = bytes32(uint256(0x1111));

        // Listed: shield a USDC note, unshield it, and credit the channel.
        _shieldWith(address(usdc), user, npk, value);
        Transaction[] memory txs = _unshieldFor(address(usdc), value, channelId, npk);
        vm.prank(broadcaster);
        adjudicator.depositFromNote(channelId, 0, txs);
        assertEq(adjudicator.heldValue(address(usdc), channelId), value);

        // Unlisted: identical inputs, only the note's token status differs — reverts.
        _shieldWith(address(unlisted), user, npk, value);
        Transaction[] memory txs2 = _unshieldFor(address(unlisted), value, channelId, npk);
        vm.prank(broadcaster);
        vm.expectRevert('Asset not configured');
        adjudicator.depositFromNote(channelId, 0, txs2);
    }

    /// @dev Shield a note of the given token: mint to `from`, approve the pool, shield.
    function _shieldWith(address tokenAddr, address from, bytes32 npk, uint256 value) internal {
        if (tokenAddr == address(usdc)) {
            _shield(from, npk, uint120(value));
            return;
        }
        unlisted.mint(from, value);
        vm.startPrank(from);
        unlisted.approve(address(pool), value);
        pool.shield(ArmadaNotes.shieldRequests(tokenAddr, npk, uint120(value)), address(0));
        vm.stopPrank();
    }

    function _unshieldFor(address tokenAddr, uint256 value, bytes32 channelId, bytes32 npk) internal returns (Transaction[] memory) {
        return ArmadaNotes.unshield(
            privacyPool,
            tokenAddr,
            address(adjudicator),
            uint120(value),
            address(adjudicator),
            adjudicator.depositBinding(channelId, 0),
            keccak256(abi.encode(npk, value, ++nullifierSeed)),
            0
        );
    }
}
