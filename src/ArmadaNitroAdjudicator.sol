// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

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
 * channel and one expected holding. Payout (N2b): an allocation of type `SHIELD` is paid by
 * minting a fresh owned commitment (`npk` = the recipient's note public key, value = the
 * allocated amount) as one more output of the same single `transactOwned` spend that pays every
 * other allocation -- never a separate shield call. Participants may be EOAs or EIP-1271
 * contracts (see NitroUtils.isAuthorizedBy).
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
        _mintPayoutCommitmentsNoChannel(singleAssetExit.asset, singleAssetExit.allocations);
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

    /// @dev N1b/N2b: the single transactOwned spend for `_settleTransferExit`, factored out to
    /// keep that function under the local-variable limit. Nullifies `oldCommitment` (if set) and
    /// mints one commitment per non-zero `exitAllocations` entry (SHIELD and non-SHIELD external
    /// folded into the same spend, c1), plus a remainder commitment back to this adjudicator when
    /// `remainder > 0`; returns the new holding (the remainder commitment, or `bytes32(0)` when
    /// nothing remains).
    function _mintTransferPayout(
        address asset,
        bytes32 oldCommitment,
        Outcome.Allocation[] memory exitAllocations,
        uint256 remainder
    ) internal returns (bytes32) {
        uint256 payoutCount = 0;
        for (uint256 i = 0; i < exitAllocations.length; i++) {
            if (exitAllocations[i].amount > 0) payoutCount++;
        }
        if (payoutCount == 0 && remainder == 0) {
            return bytes32(0);
        }

        uint256 outputCount = payoutCount + (remainder > 0 ? 1 : 0);
        CommitmentPreimage[] memory outputs = new CommitmentPreimage[](outputCount);
        uint256 k = 0;
        for (uint256 i = 0; i < exitAllocations.length; i++) {
            Outcome.Allocation memory a = exitAllocations[i];
            if (a.amount == 0) continue;
            if (uint8(a.allocationType) != SHIELD) {
                require(_isExternalDestination(a.destination), 'Internal destination not supported');
            }
            outputs[k++] = _notePreimage(asset, a.destination, a.amount);
        }
        bytes32 newHolding;
        if (remainder > 0) {
            CommitmentPreimage memory remainderPreimage = _notePreimage(asset, _addressToBytes32(address(this)), remainder);
            outputs[payoutCount] = remainderPreimage;
            newHolding = _hashCommitment(remainderPreimage);
        }
        bytes32[] memory nullifiers = oldCommitment == bytes32(0) ? new bytes32[](0) : _singleton(oldCommitment);
        _mintOwnedCommitments(nullifiers, outputs);
        return newHolding;
    }

    /// @dev N1b/N2b: the non-SHIELD-plus-SHIELD half of a generic (channelId-less) exit, used by
    /// NitroAdjudicator's transferAllAssets/concludeAndTransferAllAssets. Mints one un-nullified
    /// owned commitment per non-zero allocation in a single transactOwned call (SHIELD and
    /// non-SHIELD external folded together, c1); every non-SHIELD allocation must be an external
    /// destination (channel-to-channel is out of this family's scope, see the brief).
    function _mintPayoutCommitmentsNoChannel(
        address asset,
        Outcome.Allocation[] memory allocations
    ) internal {
        uint256 payoutCount = 0;
        for (uint256 j = 0; j < allocations.length; j++) {
            if (allocations[j].amount > 0) payoutCount++;
        }
        if (payoutCount == 0) return;
        CommitmentPreimage[] memory outputs = new CommitmentPreimage[](payoutCount);
        uint256 k = 0;
        for (uint256 j = 0; j < allocations.length; j++) {
            Outcome.Allocation memory a = allocations[j];
            if (a.amount == 0) continue;
            if (uint8(a.allocationType) != SHIELD) {
                require(_isExternalDestination(a.destination), 'Internal destination not supported');
            }
            outputs[k++] = _notePreimage(asset, a.destination, a.amount);
        }
        // N1b: no nullifier spent here -- this caller has no channel-keyed commitment context to
        // spend; the real ERC20 backing each output stays locked in the adjudicator's own wallet
        // (as it already was, via depositFromNote), redeemable later by the owning destination
        // through its own transactOwned call.
        _mintOwnedCommitments(new bytes32[](0), outputs);
    }

    /// @dev N2b: a payout commitment's preimage (npk = the allocation's destination, value = the
    /// allocated amount). The pool records a preimage for every payout commitment, so every
    /// payout is provable later via `pool.preimageOf` (c2).
    function _notePreimage(
        address asset,
        bytes32 npk,
        uint256 value
    ) internal pure returns (CommitmentPreimage memory) {
        return CommitmentPreimage({
            npk: npk,
            token: TokenData({tokenType: TokenType.ERC20, tokenAddress: asset, tokenSubID: 0}),
            value: SafeCast.toUint120(value)
        });
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
