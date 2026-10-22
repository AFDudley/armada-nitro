// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';
import {PoseidonT4} from 'armada/privacy-pool/types/PoseidonLibs.sol';
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
} from '../IArmadaPool.sol';

/**
 * @title PoolSpend
 * @notice R1 rewrite component (b): every `pool.transactOwned` call `ArmadaNitroAdjudicator`
 * makes -- deposit (N2a), transfer/payout (N1b, N2b) and reclaim, plus minting owned
 * commitments -- linked into the adjudicator at deploy time so this bytecode does not count
 * against the adjudicator's own EIP-170 budget (docs/tasks/R1-adjudicator-rewrite.md).
 * @dev Every function here is `public`, not `internal`: an `internal` library function inlines
 * into the caller and gives no size relief (Solidity `libraries.rst`). None of these functions
 * read or write the adjudicator's storage directly -- the caller passes in and writes back
 * whatever commitment value changes (R1 brief, "Storage" constraint).
 */
library PoolSpend {
    /// @dev N2b: a payout commitment's preimage (npk = the allocation's destination, value = the
    /// allocated amount). The pool records a preimage for every payout commitment, so every
    /// payout is provable later via `pool.preimageOf`.
    function notePreimage(
        address asset,
        bytes32 npk,
        uint256 value
    ) public pure returns (CommitmentPreimage memory) {
        return CommitmentPreimage({
            npk: npk,
            token: TokenData({tokenType: TokenType.ERC20, tokenAddress: asset, tokenSubID: 0}),
            value: SafeCast.toUint120(value)
        });
    }

    /// @dev N1b: the pool's commitment hash (Poseidon of npk, token id, value) -- mirrors
    /// TransactModule._hashCommitment, which the pool itself uses to validate publicOutputs.
    function hashCommitment(CommitmentPreimage memory preimage) public pure returns (bytes32) {
        return PoseidonT4.poseidon([
            preimage.npk,
            bytes32(uint256(uint160(preimage.token.tokenAddress))),
            bytes32(uint256(preimage.value))
        ]);
    }

    /**
     * @dev N1b: submit one `pool.transactOwned` transaction that nullifies `nullifiers` (0 or 1
     * entries here) and mints one fresh owned commitment per `outputs` entry, each hashed with
     * the pool's own Poseidon-based commitment hash so the pool's `_validatePublicOutputs` check
     * (every public output hashes to its commitment) passes. `address(this)` here resolves to
     * the calling adjudicator (library calls run by `DELEGATECALL`).
     */
    function mintOwnedCommitments(
        IArmadaPool pool,
        bytes32[] memory nullifiers,
        CommitmentPreimage[] memory outputs
    ) public {
        uint256 n = outputs.length;
        bytes32[] memory commitments = new bytes32[](n);
        CommitmentCiphertext[] memory ciphertexts = new CommitmentCiphertext[](n);
        for (uint256 i = 0; i < n; i++) {
            commitments[i] = hashCommitment(outputs[i]);
            ciphertexts[i] = CommitmentCiphertext({
                ciphertext: [bytes32(0), bytes32(0), bytes32(0), bytes32(0)],
                blindedSenderViewingKey: bytes32(0),
                blindedReceiverViewingKey: bytes32(0),
                annotationData: '',
                memo: ''
            });
        }

        bytes32 self = bytes32(uint256(uint160(address(this))));
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
                ownerField: self,
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

    /// @dev N1b/N2b: the single transactOwned spend for `transfer()`'s exit. Nullifies
    /// `oldCommitment` (if set) and mints one commitment per non-zero `exitAllocations` entry
    /// (SHIELD and non-SHIELD external folded into the same spend), plus a remainder commitment
    /// back to the adjudicator when `remainder > 0`; returns the new holding (the remainder
    /// commitment, or `bytes32(0)` when nothing remains). `shieldType` is the caller's SHIELD
    /// allocation-type constant.
    function mintTransferPayout(
        IArmadaPool pool,
        address asset,
        bytes32 oldCommitment,
        Outcome.Allocation[] memory exitAllocations,
        uint256 remainder,
        uint8 shieldType
    ) public returns (bytes32) {
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
            if (a.allocationType != shieldType) {
                require(uint96(bytes12(a.destination)) == 0, 'Internal destination not supported');
            }
            outputs[k++] = notePreimage(asset, a.destination, a.amount);
        }
        bytes32 newHolding;
        if (remainder > 0) {
            CommitmentPreimage memory remainderPreimage = notePreimage(
                asset,
                bytes32(uint256(uint160(address(this)))),
                remainder
            );
            outputs[payoutCount] = remainderPreimage;
            newHolding = hashCommitment(remainderPreimage);
        }
        bytes32[] memory nullifiers;
        if (oldCommitment != bytes32(0)) {
            nullifiers = new bytes32[](1);
            nullifiers[0] = oldCommitment;
        } else {
            nullifiers = new bytes32[](0);
        }
        mintOwnedCommitments(pool, nullifiers, outputs);
        return newHolding;
    }

    /// @dev N1b/N2b: the non-SHIELD-plus-SHIELD half of a generic (channelId-less) exit, used by
    /// NitroAdjudicator's transferAllAssets/concludeAndTransferAllAssets. Mints one un-nullified
    /// owned commitment per non-zero allocation in a single transactOwned call; every non-SHIELD
    /// allocation must be an external destination.
    function mintPayoutCommitmentsNoChannel(
        IArmadaPool pool,
        address asset,
        Outcome.Allocation[] memory allocations,
        uint8 shieldType
    ) public {
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
            if (a.allocationType != shieldType) {
                require(uint96(bytes12(a.destination)) == 0, 'Internal destination not supported');
            }
            outputs[k++] = notePreimage(asset, a.destination, a.amount);
        }
        mintOwnedCommitments(pool, new bytes32[](0), outputs);
    }

    /**
     * @dev N1b: move `guaranteeAmount` into `targetChannelId`'s commitment. Spends the target
     * channel's current commitment (if any; a never-funded target has none) and mints a fresh
     * owned commitment, through `pool.transactOwned`, worth its prior held value plus
     * `guaranteeAmount`. Returns the new commitment the caller writes to its own storage.
     */
    function settleReclaim(
        IArmadaPool pool,
        address asset,
        bytes32 oldCommitment,
        uint256 priorHeld,
        uint256 guaranteeAmount
    ) public returns (bytes32 newCommitment) {
        CommitmentPreimage memory newPreimage = CommitmentPreimage({
            npk: bytes32(uint256(uint160(address(this)))),
            token: TokenData({tokenType: TokenType.ERC20, tokenAddress: asset, tokenSubID: 0}),
            value: SafeCast.toUint120(priorHeld + guaranteeAmount)
        });
        CommitmentPreimage[] memory outputs = new CommitmentPreimage[](1);
        outputs[0] = newPreimage;
        bytes32[] memory nullifiers;
        if (oldCommitment != bytes32(0)) {
            nullifiers = new bytes32[](1);
            nullifiers[0] = oldCommitment;
        } else {
            nullifiers = new bytes32[](0);
        }
        mintOwnedCommitments(pool, nullifiers, outputs);
        newCommitment = hashCommitment(newPreimage);
    }
}
