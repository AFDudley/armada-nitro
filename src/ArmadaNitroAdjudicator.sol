// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';
import {PoseidonT4} from 'armada/privacy-pool/types/PoseidonLibs.sol';
import {NitroAdjudicator} from './nitro/NitroAdjudicator.sol';
import {MultiAssetHolder} from './nitro/MultiAssetHolder.sol';
import {
    IArmadaPool,
    BoundParams,
    CommitmentCiphertext,
    CommitmentPreimage,
    G1Point,
    G2Point,
    ShieldCiphertext,
    ShieldRequest,
    SnarkProof,
    TokenData,
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
 * channel and one expected holding. Payout: an allocation of type `SHIELD` is paid by shielding a
 * fresh note (`destination` = the recipient's note public key, `metadata` = the note's
 * `ShieldCiphertext`). Participants may be EOAs or EIP-1271 contracts (see NitroUtils.isAuthorizedBy).
 */
contract ArmadaNitroAdjudicator is NitroAdjudicator {
    using SafeERC20 for IERC20;

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

    /**
     * @dev N1a: the held amount of the channel collateral note. Empty commitment -> 0; a set
     * commitment reads the pool's preimage live through `preimageOf` (never a cached or passed-in
     * amount). The pool's `uint120` value is cast to `uint256` with SafeCast.
     */
    function heldValue(address asset, bytes32 channelId) public view virtual override returns (uint256) {
        bytes32 commitment = holdings[asset][channelId];
        if (uint256(commitment) == 0) {
            return 0;
        }
        CommitmentPreimage memory preimage = pool.preimageOf(commitment);
        return SafeCast.toUint256(int256(uint256(preimage.value)));
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
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        pool.transact(transactions);
        uint256 received = IERC20(asset).balanceOf(address(this)) - balanceBefore;
        require(received == note.value, 'Unshield amount mismatch');

        holdingsLock[channelId] -= 1;
        held += received;

        // N1a: the channel collateral is a pool commitment reference (bytes32), not a raw
        // balance. `commitments[0]` is a SEPARATE, pool-verified commitment (distinct from the
        // unshield's own hash at the last index) whose plaintext the caller must publish as
        // `publicOutputs[0]`; the pool's own `_recordPreimages` only ever registers a preimage it
        // has itself hash-matched to that commitment (TransactModule._validatePublicOutputs), so
        // the adjudicator here only has to check the VALUE the pool let through is the one this
        // deposit actually produced -- never a cached or caller-asserted amount.
        require(transaction.commitments.length >= 1, 'Missing collateral commitment');
        require(transaction.boundParams.publicOutputs.length >= 1, 'Missing collateral preimage');
        CommitmentPreimage calldata collateral = transaction.boundParams.publicOutputs[0];
        require(collateral.npk == _addressToBytes32(address(this)), 'Collateral not adjudicator-owned');
        require(collateral.token.tokenType == TokenType.ERC20, 'Collateral not ERC20');
        require(collateral.token.tokenAddress == asset, 'Collateral wrong asset');
        require(uint256(collateral.value) == held, 'Collateral value mismatch');
        holdings[asset][channelId] = transaction.commitments[0];
        emit Deposited(channelId, asset, held);
    }

    /**
     * @dev Pays `SHIELD` allocations by shielding one fresh note each, in a single `pool.shield`
     * call (pulling real ERC20 the adjudicator holds); other allocations are paid with a fresh,
     * un-nullified owned commitment through `pool.transactOwned` -- N1b: no raw ERC20/ETH
     * transfer for an external destination, and a channel-to-channel (non-external, non-SHIELD)
     * destination is out of this family's scope (no test exercises it; reverts if attempted).
     * Zero-amount allocations are skipped (the pool rejects zero-value notes/commitments).
     */
    function _executeSingleAssetExit(
        Outcome.SingleAssetExit memory singleAssetExit
    ) internal override {
        _payShieldAllocations(singleAssetExit.asset, singleAssetExit.assetMetadata, singleAssetExit.allocations);
        _mintExternalCommitments(singleAssetExit.asset, singleAssetExit.allocations);
    }

    /// @dev N1b: the non-SHIELD half of a generic (channelId-less) exit, used by
    /// NitroAdjudicator's transferAllAssets/concludeAndTransferAllAssets. Mints one un-nullified
    /// owned commitment per non-zero, non-SHIELD allocation (every such allocation must be an
    /// external destination -- channel-to-channel is out of this family's scope, see the brief).
    function _mintExternalCommitments(
        address asset,
        Outcome.Allocation[] memory allocations
    ) internal {
        uint256 externalCount = 0;
        for (uint256 j = 0; j < allocations.length; j++) {
            if (allocations[j].amount > 0 && allocations[j].allocationType != SHIELD) externalCount++;
        }
        if (externalCount == 0) return;
        CommitmentPreimage[] memory externalOutputs = new CommitmentPreimage[](externalCount);
        uint256 e = 0;
        for (uint256 j = 0; j < allocations.length; j++) {
            if (allocations[j].amount == 0 || allocations[j].allocationType == SHIELD) continue;
            require(_isExternalDestination(allocations[j].destination), 'Internal destination not supported');
            externalOutputs[e++] = CommitmentPreimage({
                npk: allocations[j].destination,
                token: TokenData({tokenType: TokenType.ERC20, tokenAddress: asset, tokenSubID: 0}),
                value: SafeCast.toUint120(allocations[j].amount)
            });
        }
        // N1b: no nullifier spent here -- this caller has no channel-keyed commitment context to
        // spend; the real ERC20 backing each output stays locked in the adjudicator's own wallet
        // (as it already was, via depositFromNote), redeemable later by the owning destination
        // through its own transactOwned call.
        _mintOwnedCommitments(new bytes32[](0), externalOutputs);
    }

    /**
     * @dev N1b: settle `transfer()`'s exit. Spends `holdings[asset][channelId]`'s current pool
     * commitment and mints fresh owned commitments through `pool.transactOwned`: one per
     * non-zero, non-SHIELD `exitAllocations` entry (owner-derived `npk` = the allocation's
     * destination), plus a remainder commitment back to this adjudicator when the payout is
     * partial (`totalPayouts < initialHoldings`). A full payout mints no remainder output, so
     * `holdings[asset][channelId]` is left at `bytes32(0)`. SHIELD-type allocations are paid as
     * before, by shielding a fresh note from the adjudicator's own ERC20 balance.
     */
    function _settleTransferExit(
        address asset,
        bytes32 channelId,
        Outcome.AssetMetadata memory assetMetadata,
        Outcome.Allocation[] memory exitAllocations,
        uint256 initialHoldings,
        uint256 totalPayouts
    ) internal override {
        _payShieldAllocations(asset, assetMetadata, exitAllocations);
        holdings[asset][channelId] = _mintTransferRemainder(
            asset,
            holdings[asset][channelId],
            exitAllocations,
            initialHoldings - totalPayouts
        );
        emit AllocationUpdated(channelId, asset, initialHoldings, heldValue(asset, channelId));
    }

    /// @dev N1b: the SHIELD-type half of a transfer exit, factored out to keep
    /// `_settleTransferExit` under the local-variable limit.
    function _payShieldAllocations(
        address asset,
        Outcome.AssetMetadata memory assetMetadata,
        Outcome.Allocation[] memory exitAllocations
    ) internal {
        assetMetadata; // unused here; kept for a uniform call signature with _executeSingleAssetExit
        uint256 shieldCount = 0;
        for (uint256 i = 0; i < exitAllocations.length; i++) {
            if (exitAllocations[i].amount > 0 && exitAllocations[i].allocationType == SHIELD) shieldCount++;
        }
        if (shieldCount == 0) return;
        ShieldRequest[] memory requests = new ShieldRequest[](shieldCount);
        uint256 shieldTotal = 0;
        uint256 k = 0;
        for (uint256 i = 0; i < exitAllocations.length; i++) {
            Outcome.Allocation memory allocation = exitAllocations[i];
            if (allocation.amount == 0 || allocation.allocationType != SHIELD) continue;
            requests[k++] = ShieldRequest({
                preimage: CommitmentPreimage({
                    npk: allocation.destination,
                    token: TokenData({tokenType: TokenType.ERC20, tokenAddress: asset, tokenSubID: 0}),
                    value: SafeCast.toUint120(allocation.amount)
                }),
                ciphertext: abi.decode(allocation.metadata, (ShieldCiphertext))
            });
            shieldTotal += allocation.amount;
        }
        require(asset != address(0), 'Cannot shield ETH');
        IERC20(asset).forceApprove(address(pool), shieldTotal);
        pool.shield(requests, address(0));
    }

    /// @dev N1b: the non-SHIELD half of a transfer exit, factored out to keep
    /// `_settleTransferExit` under the local-variable limit. Spends `oldCommitment` and mints one
    /// commitment per non-zero, non-SHIELD allocation plus a remainder commitment back to this
    /// adjudicator when `remainder > 0`; returns the new holding (the remainder commitment, or
    /// `bytes32(0)` when nothing remains).
    function _mintTransferRemainder(
        address asset,
        bytes32 oldCommitment,
        Outcome.Allocation[] memory exitAllocations,
        uint256 remainder
    ) internal returns (bytes32) {
        uint256 ownedCount = 0;
        for (uint256 i = 0; i < exitAllocations.length; i++) {
            if (exitAllocations[i].amount > 0 && exitAllocations[i].allocationType != SHIELD) ownedCount++;
        }
        if (ownedCount == 0 && remainder == 0) {
            return bytes32(0);
        }

        uint256 outputCount = ownedCount + (remainder > 0 ? 1 : 0);
        CommitmentPreimage[] memory outputs = new CommitmentPreimage[](outputCount);
        uint256 k = 0;
        for (uint256 i = 0; i < exitAllocations.length; i++) {
            if (exitAllocations[i].amount == 0 || exitAllocations[i].allocationType == SHIELD) continue;
            require(_isExternalDestination(exitAllocations[i].destination), 'Internal destination not supported');
            outputs[k++] = CommitmentPreimage({
                npk: exitAllocations[i].destination,
                token: TokenData({tokenType: TokenType.ERC20, tokenAddress: asset, tokenSubID: 0}),
                value: SafeCast.toUint120(exitAllocations[i].amount)
            });
        }
        bytes32 remainderCommitment;
        if (remainder > 0) {
            CommitmentPreimage memory remPreimage = CommitmentPreimage({
                npk: _addressToBytes32(address(this)),
                token: TokenData({tokenType: TokenType.ERC20, tokenAddress: asset, tokenSubID: 0}),
                value: SafeCast.toUint120(remainder)
            });
            outputs[k] = remPreimage;
            remainderCommitment = _hashCommitment(remPreimage);
        }
        bytes32[] memory nullifiers = oldCommitment == bytes32(0) ? new bytes32[](0) : _singleton(oldCommitment);
        _mintOwnedCommitments(nullifiers, outputs);
        return remainderCommitment;
    }

    /**
     * @dev N1b: move `guaranteeAmount` into `targetChannelId`'s commitment. Spends the target
     * channel's current commitment (if any; a never-funded target has none) and mints a fresh
     * owned commitment, through `pool.transactOwned`, worth its prior held value plus
     * `guaranteeAmount`.
     */
    function _settleReclaimExit(
        address asset,
        bytes32 targetChannelId,
        uint256 guaranteeAmount
    ) internal override {
        bytes32 oldCommitment = holdings[asset][targetChannelId];
        uint256 priorHeld = heldValue(asset, targetChannelId);
        CommitmentPreimage memory newPreimage = CommitmentPreimage({
            npk: _addressToBytes32(address(this)),
            token: TokenData({tokenType: TokenType.ERC20, tokenAddress: asset, tokenSubID: 0}),
            value: SafeCast.toUint120(priorHeld + guaranteeAmount)
        });
        CommitmentPreimage[] memory outputs = new CommitmentPreimage[](1);
        outputs[0] = newPreimage;
        bytes32[] memory nullifiers = oldCommitment == bytes32(0) ? new bytes32[](0) : _singleton(oldCommitment);
        _mintOwnedCommitments(nullifiers, outputs);
        holdings[asset][targetChannelId] = _hashCommitment(newPreimage);
    }

    /**
     * @dev N1b: submit one `pool.transactOwned` transaction that nullifies `nullifiers` (0 or 1
     * entries here) and mints one fresh owned commitment per `outputs` entry, each hashed with
     * the pool's own Poseidon-based commitment hash so the pool's `_validatePublicOutputs` check
     * (every public output hashes to its commitment) passes.
     */
    function _mintOwnedCommitments(
        bytes32[] memory nullifiers,
        CommitmentPreimage[] memory outputs
    ) internal {
        uint256 n = outputs.length;
        bytes32[] memory commitments = new bytes32[](n);
        CommitmentCiphertext[] memory ciphertexts = new CommitmentCiphertext[](n);
        for (uint256 i = 0; i < n; i++) {
            commitments[i] = _hashCommitment(outputs[i]);
            ciphertexts[i] = CommitmentCiphertext({
                ciphertext: [bytes32(0), bytes32(0), bytes32(0), bytes32(0)],
                blindedSenderViewingKey: bytes32(0),
                blindedReceiverViewingKey: bytes32(0),
                annotationData: '',
                memo: ''
            });
        }

        Transaction[] memory txs = new Transaction[](1);
        txs[0] = Transaction({
            proof: SnarkProof({
                a: G1Point(0, 0),
                b: G2Point([uint256(0), 0], [uint256(0), 0]),
                c: G1Point(0, 0)
            }),
            merkleRoot: pool.merkleRoot(),
            nullifiers: nullifiers,
            commitments: commitments,
            boundParams: BoundParams({
                treeNumber: uint16(pool.treeNumber()),
                minGasPrice: 0,
                unshield: UnshieldType.NONE,
                chainID: uint64(block.chainid),
                adaptContract: address(this),
                adaptParams: bytes32(0),
                commitmentCiphertext: ciphertexts,
                ownerField: _addressToBytes32(address(this)),
                publicOutputs: outputs
            }),
            unshieldPreimage: CommitmentPreimage({
                npk: bytes32(0),
                token: TokenData({tokenType: TokenType.ERC20, tokenAddress: address(0), tokenSubID: 0}),
                value: 0
            })
        });
        pool.transactOwned(txs);
    }

    /// @dev N1b: the pool's commitment hash (Poseidon of npk, token id, value) -- mirrors
    /// TransactModule._hashCommitment, which the pool itself uses to validate publicOutputs.
    function _hashCommitment(CommitmentPreimage memory preimage) internal pure returns (bytes32) {
        return PoseidonT4.poseidon([
            preimage.npk,
            bytes32(uint256(uint160(preimage.token.tokenAddress))),
            bytes32(uint256(preimage.value))
        ]);
    }

    function _singleton(bytes32 value) internal pure returns (bytes32[] memory out) {
        out = new bytes32[](1);
        out[0] = value;
    }
}
