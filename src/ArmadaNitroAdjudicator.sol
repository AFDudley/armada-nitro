// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';
import {NitroAdjudicator} from './nitro/NitroAdjudicator.sol';
import {MultiAssetHolder} from './nitro/MultiAssetHolder.sol';
import {
    IArmadaPool,
    CommitmentPreimage,
    ShieldCiphertext,
    ShieldRequest,
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
     * @dev Pays `SHIELD` allocations by shielding one fresh note each, in a single `pool.shield`
     * call; other allocations are paid as in go-nitro. Zero-amount allocations are skipped (the pool
     * rejects zero-value notes). The pool charges its shield fee, so a note's value is the allocation
     * less that fee.
     */
    function _executeSingleAssetExit(
        Outcome.SingleAssetExit memory singleAssetExit
    ) internal override {
        address asset = singleAssetExit.asset;
        Outcome.Allocation[] memory allocations = singleAssetExit.allocations;

        uint256 shieldCount = 0;
        for (uint256 j = 0; j < allocations.length; j++) {
            if (allocations[j].allocationType == SHIELD && allocations[j].amount > 0) shieldCount++;
        }
        ShieldRequest[] memory requests = new ShieldRequest[](shieldCount);
        uint256 shieldTotal = 0;
        uint256 k = 0;

        for (uint256 j = 0; j < allocations.length; j++) {
            Outcome.Allocation memory allocation = allocations[j];
            if (allocation.allocationType == SHIELD) {
                if (allocation.amount == 0) continue;
                requests[k++] = ShieldRequest({
                    preimage: CommitmentPreimage({
                        npk: allocation.destination,
                        token: TokenData({
                            tokenType: TokenType.ERC20,
                            tokenAddress: asset,
                            tokenSubID: 0
                        }),
                        value: SafeCast.toUint120(allocation.amount)
                    }),
                    ciphertext: abi.decode(allocation.metadata, (ShieldCiphertext))
                });
                shieldTotal += allocation.amount;
            } else if (_isExternalDestination(allocation.destination)) {
                _transferAsset(asset, _bytes32ToAddress(allocation.destination), allocation.amount);
            } else {
                holdings[asset][allocation.destination] = bytes32(uint256(holdings[asset][allocation.destination]) + allocation.amount);
            }
        }

        if (shieldCount > 0) {
            require(asset != address(0), 'Cannot shield ETH');
            IERC20(asset).forceApprove(address(pool), shieldTotal);
            pool.shield(requests, address(0));
        }
    }
}
