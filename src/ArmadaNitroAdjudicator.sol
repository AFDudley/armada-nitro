// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';
import {NitroAdjudicator} from './nitro/NitroAdjudicator.sol';
import {MultiAssetHolder} from './nitro/MultiAssetHolder.sol';
import {CommitmentHoldings} from './armada/libraries/CommitmentHoldings.sol';
import {PoolSpend} from './armada/libraries/PoolSpend.sol';
import {
    IArmadaPool,
    CommitmentPreimage,
    TokenType,
    Transaction,
    UnshieldType
} from './armada/IArmadaPool.sol';

/// @dev Allocation type for a payout that shields a fresh note in the pool.
uint8 constant SHIELD_ALLOCATION_TYPE = 3;

/**
 * @title ArmadaNitroAdjudicator
 * @notice go-nitro's adjudicator with note-native custody on an Armada pool.
 * @dev Funding: `depositFromNote` submits an Armada unshield that is bound, inside the proof, to one
 * channel and one expected holding. Payout (N2b): an allocation of type `SHIELD` is paid by
 * minting a fresh owned commitment (`npk` = the recipient's note public key, value = the
 * allocated amount) as one more output of the same single `transactOwned` spend that pays every
 * other allocation -- never a separate shield call. Participants may be EOAs or EIP-1271
 * contracts (see NitroUtils.isAuthorizedBy).
 * @dev R1 rewrite: every `pool.transactOwned` spend (component (b), `PoolSpend`) and the
 * commitment-holdings read (component (a), `CommitmentHoldings`) live in external libraries
 * linked at deploy time -- `internal` library functions inline into the caller and give no size
 * relief, so every function this contract delegates to is `public` on its library
 * (docs/tasks/R1-adjudicator-rewrite.md). Neither library reads or writes this contract's
 * storage directly; this contract reads `holdings` itself and writes back whatever the library
 * returns.
 */
contract ArmadaNitroAdjudicator is NitroAdjudicator {
    /// @notice Allocation type for a payout that shields a fresh note in the pool.
    uint8 public constant SHIELD = SHIELD_ALLOCATION_TYPE;

    /// @notice The Armada pool this adjudicator funds from and settles into.
    IArmadaPool public immutable pool;

    /// @notice The set of tokens the hub has configured for this adjudicator's channels.
    mapping(address => bool) public configuredAssets;

    /// @notice Whether the token is on the adjudicator's configured asset list.
    function isAsset(address asset) public view returns (bool) {
        return configuredAssets[asset];
    }

    /// @dev N1a: see `CommitmentHoldings.heldValue`.
    function heldValue(address asset, bytes32 channelId) public view virtual override returns (uint256) {
        return CommitmentHoldings.heldValue(pool, holdings[asset][channelId]);
    }

    constructor(IArmadaPool pool_, address[] memory assets_) {
        pool = pool_;
        for (uint256 i = 0; i < assets_.length; i++) {
            configuredAssets[assets_[i]] = true;
        }
    }

    /**
     * @notice The `adaptParams` an unshield must carry to fund `channelId` on top of `expectedHeld`.
     * @param channelId Channel to credit.
     * @param expectedHeld Holdings of the note's token against `channelId` before the deposit.
     * @return The binding committed to by the unshield proof.
     */
    function depositBinding(bytes32 channelId, uint256 expectedHeld) public pure returns (bytes32) {
        return keccak256(abi.encode(channelId, expectedHeld));
    }

    /**
     * @notice Fund `channelId` from a shielded note.
     * @dev `transactions` must hold exactly one Armada transaction: a local unshield
     * (`UnshieldType.NORMAL`) of an ERC20 note to this contract, with `adaptContract` = this contract
     * and `adaptParams` = `depositBinding(channelId, expectedHeld)`. Both are public inputs of the
     * proof, and the pool accepts the transaction only from `adaptContract`, so the unshield can be
     * submitted only here and only for this channel at this holding. Anyone (e.g. a broadcaster) may
     * submit it.
     * @dev N2a: the deposited value never leaves the pool. The transaction's single output
     * (`commitments[0]`) must be a fresh contract-owned commitment whose pool-registered preimage
     * (read live via `pool.preimageOf`, never a caller-asserted value) has `npk` derived from
     * `address(this)`, a token on `isAsset`, and a value equal to the new cumulative holding
     * (`expectedHeld + note.value`). No `IERC20.balanceOf` read is used for deposit accounting.
     * @param channelId Channel to credit.
     * @param expectedHeld Holdings of the note's token against `channelId` before the deposit.
     * @param transactions The single unshield transaction.
     */
    function depositFromNote(
        bytes32 channelId,
        uint256 expectedHeld,
        Transaction[] calldata transactions
    ) external {
        require(!_isExternalDestination(channelId), 'Deposit to external destination');
        require(transactions.length == 1, 'Exactly one transaction');
        Transaction calldata transaction = transactions[0];
        require(transaction.boundParams.unshield == UnshieldType.NORMAL, 'Not an unshield');
        require(transaction.boundParams.adaptContract == address(this), 'Wrong adaptContract');
        require(
            transaction.boundParams.adaptParams == depositBinding(channelId, expectedHeld),
            'Wrong adaptParams'
        );
        CommitmentPreimage calldata note = transaction.unshieldPreimage;
        require(note.npk == _addressToBytes32(address(this)), 'Unshield not to adjudicator');
        require(note.token.tokenType == TokenType.ERC20, 'Not an ERC20 note');

        address asset = note.token.tokenAddress;
        require(isAsset(asset), 'Asset not configured');
        uint256 held = heldValue(asset, channelId);
        require(held == expectedHeld, 'held != expectedHeld');

        // guard: no nested call may run on this channel while this deposit is in progress.
        require(holdingsLock[channelId] == 0, 'Re-entered while in progress');
        holdingsLock[channelId] += 1;
        pool.transact(transactions);
        // N2a: the deposit moves value into a fresh contract-owned note inside the pool; no ERC-20
        // leaves the pool to the adjudicator's raw balance. The single output (newCommitment) is a
        // contract-owned commitment; the adjudicator verifies the pool's own preimage for it (value,
        // owner and asset) before crediting the channel holding -- never a caller-asserted amount.
        bytes32 newCommitment = transaction.commitments[0];
        CommitmentPreimage memory preimage = pool.preimageOf(newCommitment);
        uint256 amount = held + uint256(note.value);
        require(preimage.npk == _addressToBytes32(address(this)), 'Collateral not adjudicator-owned');
        require(preimage.token.tokenType == TokenType.ERC20, 'Collateral not ERC20');
        require(preimage.token.tokenAddress == asset, 'Collateral wrong asset');
        require(isAsset(preimage.token.tokenAddress), 'Collateral asset not configured');
        require(uint256(preimage.value) == amount, 'Collateral value mismatch');
        holdings[asset][channelId] = newCommitment;
        holdingsLock[channelId] -= 1;
        emit Deposited(channelId, asset, amount);
    }

    /**
     * @dev N2b: a SHIELD payout is one more output of N1b's single `transactOwned` spend on the
     * pool (c1: not a separate shield call against a raw ERC-20 balance, which cannot stand
     * now that `holdings` is a commitment). Each non-zero allocation -- SHIELD or non-SHIELD
     * external -- mints a commitment of its own amount (c2), zero-amount allocations are skipped
     * (c3), and the mechanism used for non-SHIELD (ETH or raw-asset) allocations is the unchanged
     * N1b owned-commitment mint, never a raw `_transferAsset` (c4). The spend carries no protocol
     * fee: it is a plain output with no fee tag and no cumulativeFees coupling (c5).
     */
    function _executeSingleAssetExit(
        Outcome.SingleAssetExit memory singleAssetExit
    ) internal override {
        PoolSpend.mintPayoutCommitmentsNoChannel(pool, singleAssetExit.asset, singleAssetExit.allocations, SHIELD);
    }

    /**
     * @dev N1b/N2b: settle `transfer()`'s exit. Spends `holdings[asset][channelId]`'s current pool
     * commitment and mints fresh owned commitments through a single `pool.transactOwned` call: one
     * per non-zero `exitAllocations` entry -- SHIELD (c1/c2/c3: the payout note, npk = the
     * allocation's destination) folded alongside non-SHIELD external (owner-derived npk, c4: the
     * unchanged N1b mechanism) -- plus a remainder commitment back to this adjudicator when the
     * payout is partial (`totalPayouts < initialHoldings`). A full payout mints no remainder
     * output, so `holdings[asset][channelId]` is left at `bytes32(0)`. No protocol fee (c5).
     */
    function _settleTransferExit(
        address asset,
        bytes32 channelId,
        Outcome.AssetMetadata memory assetMetadata,
        Outcome.Allocation[] memory exitAllocations,
        uint256 initialHoldings,
        uint256 totalPayouts
    ) internal override {
        assetMetadata; // unused here; kept for a uniform call signature with _executeSingleAssetExit
        holdings[asset][channelId] = _mintTransferPayout(
            asset,
            holdings[asset][channelId],
            exitAllocations,
            initialHoldings - totalPayouts
        );
        emit AllocationUpdated(channelId, asset, initialHoldings, heldValue(asset, channelId));
    }

    /// @dev N1b/N2b: thin wrapper the test harness exposes directly; the real spend lives in
    /// `PoolSpend.mintTransferPayout`.
    function _mintTransferPayout(
        address asset,
        bytes32 oldCommitment,
        Outcome.Allocation[] memory exitAllocations,
        uint256 remainder
    ) internal returns (bytes32) {
        return PoolSpend.mintTransferPayout(pool, asset, oldCommitment, exitAllocations, remainder, SHIELD);
    }

    /**
     * @dev N1b: move `guaranteeAmount` into `targetChannelId`'s commitment via
     * `PoolSpend.settleReclaim`.
     */
    function _settleReclaimExit(
        address asset,
        bytes32 targetChannelId,
        uint256 guaranteeAmount
    ) internal override {
        bytes32 oldCommitment = holdings[asset][targetChannelId];
        uint256 priorHeld = heldValue(asset, targetChannelId);
        holdings[asset][targetChannelId] = PoolSpend.settleReclaim(
            pool,
            asset,
            oldCommitment,
            priorHeld,
            guaranteeAmount
        );
    }
}
