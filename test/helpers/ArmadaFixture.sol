// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test, Vm} from 'forge-std/Test.sol';
import {PrivacyPool} from 'armada/privacy-pool/PrivacyPool.sol';
import {MockUSDCV2} from 'armada/cctp/MockUSDCV2.sol';
import {IArmadaPool, CommitmentPreimage, ShieldCiphertext, Transaction} from 'src/armada/IArmadaPool.sol';
import {ArmadaNotes} from './ArmadaNotes.sol';

/// @dev Armada's real PrivacyPool with the circomlib Poseidon libraries; only the SNARK check is off.
abstract contract ArmadaFixture is Test {
    MockUSDCV2 internal usdc;
    PrivacyPool internal privacyPool;
    IArmadaPool internal pool;
    uint256 private nullifierSeed;

    function _deployArmada() internal {
        ArmadaNotes.placePoseidon(false);
        (privacyPool, usdc) = ArmadaNotes.deploy(address(this));
        pool = IArmadaPool(address(privacyPool));
    }

    /// @dev Shield `value` USDC from `from` into a note for `npk`.
    function _shield(address from, bytes32 npk, uint120 value) internal {
        usdc.mint(from, value);
        vm.startPrank(from);
        usdc.approve(address(pool), value);
        pool.shield(ArmadaNotes.shieldRequests(address(usdc), npk, value), address(0));
        vm.stopPrank();
    }

    /// @dev `priorHeld` is the channel's held value (for `recipient`'s asset) BEFORE this
    /// unshield lands -- it becomes the pool-registered cumulative collateral commitment's value
    /// (see ArmadaNotes.unshield), matching the `expectedHeld` bound into `adaptParams`.
    function _unshield(
        address recipient,
        uint120 value,
        address adaptContract,
        bytes32 adaptParams,
        uint256 priorHeld
    ) internal returns (Transaction[] memory) {
        return
            ArmadaNotes.unshield(
                privacyPool,
                address(usdc),
                recipient,
                value,
                adaptContract,
                adaptParams,
                bytes32(++nullifierSeed),
                priorHeld
            );
    }

    function _shieldedNotes(
        Vm.Log[] memory logs
    ) internal view returns (CommitmentPreimage[] memory, ShieldCiphertext[] memory) {
        return ArmadaNotes.shieldedNotes(logs, address(pool));
    }
}
