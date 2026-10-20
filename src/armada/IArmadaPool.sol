// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// The subset of the Armada PrivacyPool ABI the adjudicator calls. The types are Railgun's
// (`contracts/railgun/logic/Globals.sol` in ship-armada/armada-poc); the tests deploy the real pool
// against this interface, which pins the encoding.

enum TokenType {
    ERC20,
    ERC721,
    ERC1155
}

struct TokenData {
    TokenType tokenType;
    address tokenAddress;
    uint256 tokenSubID;
}

struct CommitmentPreimage {
    bytes32 npk;
    TokenData token;
    uint120 value;
}

struct ShieldCiphertext {
    bytes32[3] encryptedBundle;
    bytes32 shieldKey;
}

struct ShieldRequest {
    CommitmentPreimage preimage;
    ShieldCiphertext ciphertext;
}

struct CommitmentCiphertext {
    bytes32[4] ciphertext;
    bytes32 blindedSenderViewingKey;
    bytes32 blindedReceiverViewingKey;
    bytes annotationData;
    bytes memo;
}

enum UnshieldType {
    NONE,
    NORMAL,
    REDIRECT
}

struct BoundParams {
    uint16 treeNumber;
    uint72 minGasPrice;
    UnshieldType unshield;
    uint64 chainID;
    address adaptContract;
    bytes32 adaptParams;
    CommitmentCiphertext[] commitmentCiphertext;
    // P2a: the circuit's public owner input, zero for a non-owned transaction.
    bytes32 ownerField;
    // P2a: plaintext preimages for contract-owned outputs; zero-length when none.
    CommitmentPreimage[] publicOutputs;
}

struct G1Point {
    uint256 x;
    uint256 y;
}

struct G2Point {
    uint256[2] x;
    uint256[2] y;
}

struct SnarkProof {
    G1Point a;
    G2Point b;
    G1Point c;
}

struct Transaction {
    SnarkProof proof;
    bytes32 merkleRoot;
    bytes32[] nullifiers;
    bytes32[] commitments;
    BoundParams boundParams;
    CommitmentPreimage unshieldPreimage;
}

interface IArmadaPool {
    function shield(ShieldRequest[] calldata shieldRequests, address integrator) external;

    function transact(Transaction[] calldata transactions) external;

    /**
     * @dev N1a: the public preimage registry. Reads a note's `token` and `value` from the
     * commitment alone, with no off-chain index (lab book decision 3 / 11: the creator publishes
     * the preimage in the creating transaction; the adjudicator verifies it before crediting).
     * The heldValue view maps this pool's `uint120` value through SafeCast.
     */
    function preimageOf(bytes32 commitment) external view returns (CommitmentPreimage memory);

    /**
     * @dev P2a: spends a note whose `npk` is derived from `msg.sender` with no EdDSA signature;
     * the pool checks `msg.sender == owner` (lab book decision 2: contract-owned spend authorized
     * by `msg.sender == owner`). Callable only by the owning contract.
     */
    function transactOwned(Transaction[] calldata transactions) external;
}
