// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FROST} from 'frost-secp256k1-evm/FROST.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import {IERC1271} from '@openzeppelin/contracts/interfaces/IERC1271.sol';

/**
 * @title HubCustodian
 * @notice A hub's stable on-chain principal and channel participant.
 * @dev Two keys:
 * - The FROST(secp256k1, KECCAK-256) group key authorizes every cold operation through `execute`:
 *   moving the hub's funds (e.g. approving and depositing into an adjudicator), authorizing and
 *   revoking delegates, and rotating the group key.
 * - Delegate ECDSA keys sign channel states. The adjudicator accepts them through
 *   `isValidSignature`, so the channel's participant list (this contract's address) never changes
 *   when a delegate does.
 *
 * Revocation is delayed by `revocationDelay`. A counterparty holding a state signed by a delegate
 * needs that signature to verify until the state is on chain; the `DelegateRevocationScheduled`
 * event is its cue to checkpoint. `revocationDelay` must therefore exceed the challenge duration of
 * every channel this custodian participates in plus the counterparty's response time.
 */
contract HubCustodian is IERC1271 {
    struct GroupSignature {
        uint256 commitmentX;
        uint256 commitmentY;
        uint256 z;
    }

    struct Delegate {
        bool authorized;
        /// Time from which the delegate's signatures are rejected; zero if no revocation is scheduled.
        uint64 revokedAt;
    }

    bytes32 public constant OPERATION_TYPEHASH =
        keccak256('HubCustodian.Operation(uint256 chainId,address custodian,uint256 nonce,address target,uint256 value,bytes32 dataHash)');

    uint256 public immutable revocationDelay;
    uint256 public groupKeyX;
    uint256 public groupKeyY;
    uint256 public nonce;
    mapping(address => Delegate) public delegates;

    event Executed(uint256 indexed nonce, address indexed target, uint256 value, bytes data);
    event GroupKeyRotated(uint256 groupKeyX, uint256 groupKeyY);
    event DelegateAuthorized(address indexed delegate);
    event DelegateRevocationScheduled(address indexed delegate, uint64 revokedAt);

    error InvalidGroupKey();
    error InvalidGroupSignature();
    error OnlySelf();
    error NotAnActiveDelegate(address delegate);

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    constructor(uint256 groupKeyX_, uint256 groupKeyY_, uint256 revocationDelay_) {
        revocationDelay = revocationDelay_;
        _setGroupKey(groupKeyX_, groupKeyY_);
    }

    receive() external payable {}

    /**
     * @notice The message the group signs to authorize operation `nonce_`.
     */
    function operationHash(
        uint256 nonce_,
        address target,
        uint256 value,
        bytes calldata data
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(OPERATION_TYPEHASH, block.chainid, address(this), nonce_, target, value, keccak256(data))
        );
    }

    /**
     * @notice Perform one call authorized by the group key. Calls to this contract reach the
     * `onlySelf` administration functions.
     * @param target Contract to call.
     * @param value Wei to send.
     * @param data Calldata.
     * @param signature Group signature over `operationHash(nonce, target, value, data)`.
     * @return result The call's return data. A failing call reverts with its revert data.
     */
    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        GroupSignature calldata signature
    ) external payable returns (bytes memory result) {
        uint256 current = nonce;
        bool valid = FROST.verifySignature(
            groupKeyX,
            groupKeyY,
            signature.commitmentX,
            signature.commitmentY,
            signature.z,
            operationHash(current, target, value, data)
        );
        if (!valid) revert InvalidGroupSignature();
        nonce = current + 1;

        bool success;
        (success, result) = target.call{value: value}(data);
        if (!success) {
            assembly ('memory-safe') {
                revert(add(result, 0x20), mload(result))
            }
        }
        emit Executed(current, target, value, data);
    }

    /// @notice Authorize `delegate` to sign channel states; cancels any scheduled revocation.
    function authorizeDelegate(address delegate) external onlySelf {
        delegates[delegate] = Delegate({authorized: true, revokedAt: 0});
        emit DelegateAuthorized(delegate);
    }

    /// @notice Stop accepting `delegate`'s signatures `revocationDelay` seconds from now.
    function revokeDelegate(address delegate) external onlySelf {
        if (!isActiveDelegate(delegate)) revert NotAnActiveDelegate(delegate);
        Delegate storage entry = delegates[delegate];
        if (entry.revokedAt != 0) return;
        uint64 revokedAt = uint64(block.timestamp + revocationDelay);
        entry.revokedAt = revokedAt;
        emit DelegateRevocationScheduled(delegate, revokedAt);
    }

    /// @notice Replace the group key.
    function rotateGroupKey(uint256 groupKeyX_, uint256 groupKeyY_) external onlySelf {
        _setGroupKey(groupKeyX_, groupKeyY_);
    }

    /// @notice Whether `delegate`'s signatures are currently accepted.
    function isActiveDelegate(address delegate) public view returns (bool) {
        Delegate memory entry = delegates[delegate];
        return entry.authorized && (entry.revokedAt == 0 || block.timestamp < entry.revokedAt);
    }

    /// @inheritdoc IERC1271
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        (address signer, ECDSA.RecoverError recoverError) = ECDSA.tryRecover(hash, signature);
        if (recoverError == ECDSA.RecoverError.NoError && isActiveDelegate(signer)) {
            return IERC1271.isValidSignature.selector;
        }
        return 0xffffffff;
    }

    function _setGroupKey(uint256 x, uint256 y) private {
        if (!FROST.isValidPublicKey(x, y)) revert InvalidGroupKey();
        groupKeyX = x;
        groupKeyY = y;
        emit GroupKeyRotated(x, y);
    }
}
