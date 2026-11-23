// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.31;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

library PoseidonT3 {
    function poseidon(bytes32[2] memory input) public pure returns (bytes32) {
        (input);
        revert("PoseidonT3: library not linked");
    }
}

library PoseidonT4 {
    function poseidon(bytes32[3] memory input) public pure returns (bytes32) {
        (input);
        revert("PoseidonT4: library not linked");
    }
}

contract PoolSol {
    error notFeeAdmin();
    error invalidFeeRatio();
    error arithmetic();
    error valueTooLarge();
    error tokenRejected();
    error poseidonFailed();
    error treeFull();
    error shapeTooLarge();
    error unknownRoot();
    error nullifierSpent();
    error keyNotSet();
    error proofRejected();
    error ownerMismatch();
    error batchTooLarge();
    error tooManyKeys();
    error ecAddFailed();
    error ecMulFailed();
    error pairingFailed();
    error pointOutsideField();
    error pointNotOnCurve();
    error icLengthMismatch();
    error inputOutsideField();
    error tooManyInputs();
    event Shielded(bytes32 commitment, uint256 amount);
    event Transacted(bytes32 merkleRoot);
    event FeeRatioSet(uint128 num, uint128 den);
    enum UnshieldType { none, normal, redirect }
    enum TokenType { erc20, erc721, erc1155 }
    struct BoundParamsCore {
        uint16 treeNumber;
        uint72 minGasPrice;
        UnshieldType unshield;
        uint64 chainID;
        address adaptContract;
        bytes32 adaptParams;
        CommitmentCiphertext[] commitmentCiphertext;
    }
    struct CommitmentCiphertext {
        bytes32[4] ciphertext;
        bytes32 blindedSenderViewingKey;
        bytes32 blindedReceiverViewingKey;
        bytes annotationData;
        bytes memo;
    }
    struct BoundParams {
        uint16 treeNumber;
        uint72 minGasPrice;
        UnshieldType unshield;
        uint64 chainID;
        address adaptContract;
        bytes32 adaptParams;
        CommitmentCiphertext[] commitmentCiphertext;
        bytes32 ownerField;
        CommitmentPreimage[] publicOutputs;
    }
    struct CommitmentPreimage {
        bytes32 npk;
        TokenData token;
        uint120 value;
    }
    struct TokenData {
        TokenType tokenType;
        address tokenAddress;
        uint256 tokenSubID;
    }
    struct G1Point {
        uint256 x;
        uint256 y;
    }
    struct G2Point {
        uint256[2] x;
        uint256[2] y;
    }
    struct VerifyingKey {
        string artifactsIPFSHash;
        G1Point alpha1;
        G2Point beta2;
        G2Point gamma2;
        G2Point delta2;
        G1Point[] ic;
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
    struct FeeRatio {
        uint128 num;
        uint128 den;
    }
    struct ShapedKey {
        uint256 nullifiers;
        uint256 commitments;
        VerifyingKey key;
    }
    uint256 internal constant PRIME_Q = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
    uint256 internal constant SNARK_SCALAR_FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 internal treeNumber;
    uint256 internal nextLeafIndex;
    bytes32[16] internal filledSubTrees;
    bytes32 internal merkleRoot;
    mapping(uint256 => mapping(bytes32 => bool)) internal rootHistory;
    mapping(uint256 => mapping(bytes32 => bool)) internal nullifiers;
    mapping(bytes32 => CommitmentPreimage) internal preimageOf;
    mapping(address => uint256) internal treasuryFees;
    FeeRatio internal feeRatio;
    mapping(uint256 => mapping(uint256 => VerifyingKey)) internal verificationKeys;
    mapping(uint256 => mapping(uint256 => VerifyingKey)) internal ownedVerificationKeys;
    address internal immutable feeAdmin;
    address internal immutable treasury;
    uint256 internal immutable maxBatch;

    constructor(address feeAdmin_, address treasury_, uint256 maxBatch_, ShapedKey[] memory keys, ShapedKey[] memory ownedKeys) {
        feeAdmin = feeAdmin_;
        treasury = treasury_;
        maxBatch = maxBatch_;
        if (!((keys.length <= 64))) revert tooManyKeys();
        for (uint256 kIndex = 0; kIndex < keys.length; ++kIndex) {
            ShapedKey memory k = keys[kIndex];
            verificationKeys[k.nullifiers][k.commitments] = k.key;
        }
        if (!((ownedKeys.length <= 64))) revert tooManyKeys();
        for (uint256 kIndex = 0; kIndex < ownedKeys.length; ++kIndex) {
            ShapedKey memory k = ownedKeys[kIndex];
            ownedVerificationKeys[k.nullifiers][k.commitments] = k.key;
        }
    }

    function insertLeaf(bytes32 leaf) internal {
        uint256 i = nextLeafIndex;
        if (!((i < 65536))) revert treeFull();
        bytes32 root = merkleRoot;
        bytes32 root1 = PoseidonT3.poseidon([root, leaf]);
        merkleRoot = root1;
        uint256 t = treeNumber;
        rootHistory[t][root1] = true;
        uint256 i1 = 0;
        unchecked { i1 = (i + 1); }
        if (!((i1 >= i))) revert arithmetic();
        nextLeafIndex = i1;
    }

    function boundParamsHash(BoundParams memory bp) internal pure returns (uint256) {
        BoundParamsCore memory core = BoundParamsCore(bp.treeNumber, bp.minGasPrice, bp.unshield, bp.chainID, bp.adaptContract, bp.adaptParams, bp.commitmentCiphertext);
        bytes32 h = keccak256(abi.encode(core));
        uint256 w = (uint256(h) % SNARK_SCALAR_FIELD);
        return w;
    }

    function ecAdd(G1Point memory p1, G1Point memory p2) internal view returns (G1Point memory) {
        (bool outOk, bytes memory out) = address(6).staticcall(abi.encode(p1.x, p1.y, p2.x, p2.y));
        if (!outOk) revert ecAddFailed();
        G1Point memory r = abi.decode(out, (G1Point));
        return r;
    }

    function ecMul(G1Point memory p, uint256 s) internal view returns (G1Point memory) {
        (bool outOk, bytes memory out) = address(7).staticcall(abi.encode(p.x, p.y, s));
        if (!outOk) revert ecMulFailed();
        G1Point memory r = abi.decode(out, (G1Point));
        return r;
    }

    function negate(G1Point memory p) internal pure returns (G1Point memory) {
        bool isZero = ((p.x == 0) && (p.y == 0));
        if (!((isZero || ((p.x < PRIME_Q) && (p.y < PRIME_Q))))) revert pointOutsideField();
        uint256 ySquared = mulmod(p.y, p.y, PRIME_Q);
        uint256 xSquared = mulmod(p.x, p.x, PRIME_Q);
        uint256 xCubed = mulmod(xSquared, p.x, PRIME_Q);
        uint256 xCubedPlusB = addmod(xCubed, 3, PRIME_Q);
        if (!((isZero || (ySquared == xCubedPlusB)))) revert pointNotOnCurve();
        if (!((p.y <= PRIME_Q))) revert arithmetic();
        uint256 qMinusY = 0;
        unchecked { qMinusY = (PRIME_Q - p.y); }
        uint256 negY = (qMinusY % PRIME_Q);
        G1Point memory r = G1Point(p.x, negY);
        return r;
    }

    function pairing4(G1Point memory a1, G2Point memory a2, G1Point memory b1, G2Point memory b2, G1Point memory c1, G2Point memory c2, G1Point memory d1, G2Point memory d2) internal view returns (bool) {
        (bool outOk, bytes memory out) = address(8).staticcall(abi.encode(a1.x, a1.y, a2.x[0], a2.x[1], a2.y[0], a2.y[1], b1.x, b1.y, b2.x[0], b2.x[1], b2.y[0], b2.y[1], c1.x, c1.y, c2.x[0], c2.x[1], c2.y[0], c2.y[1], d1.x, d1.y, d2.x[0], d2.x[1], d2.y[0], d2.y[1]));
        if (!outOk) revert pairingFailed();
        uint256 r = abi.decode(out, (uint256));
        return (r != 0);
    }

    function snarkVerify(VerifyingKey memory vk, SnarkProof memory proof, uint256[] memory inputs) internal view returns (bool) {
        if (!((vk.ic.length == (inputs.length + 1)))) revert icLengthMismatch();
        if (!((0 < vk.ic.length))) revert icLengthMismatch();
        G1Point memory ic0 = vk.ic[0];
        G1Point memory vkX = ic0;
        if (!((inputs.length <= 64))) revert tooManyInputs();
        for (uint256 inputIndex = 0; inputIndex < inputs.length; ++inputIndex) {
            uint256 input = inputs[inputIndex];
            if (!((input < SNARK_SCALAR_FIELD))) revert inputOutsideField();
            if (!(((inputIndex + 1) < vk.ic.length))) revert icLengthMismatch();
            G1Point memory icNext = vk.ic[(inputIndex + 1)];
            G1Point memory term = ecMul(icNext, input);
            G1Point memory next = ecAdd(vkX, term);
            vkX = next;
        }
        G1Point memory negA = negate(proof.a);
        bool ok = pairing4(negA, proof.b, vk.alpha1, vk.beta2, vkX, vk.gamma2, proof.c, vk.delta2);
        return ok;
    }

    function checkCommon(Transaction memory txn) internal view {
        uint256 tn = txn.boundParams.treeNumber;
        bool known = rootHistory[tn][txn.merkleRoot];
        if (!(known)) revert unknownRoot();
        if (!((txn.nullifiers.length <= 16))) revert shapeTooLarge();
        for (uint256 nIndex = 0; nIndex < txn.nullifiers.length; ++nIndex) {
            bytes32 n = txn.nullifiers[nIndex];
            bool spent = nullifiers[tn][n];
            if (!(!(spent))) revert nullifierSpent();
        }
    }

    function verifyPlain(Transaction memory txn) internal view {
        VerifyingKey memory vk = verificationKeys[txn.nullifiers.length][txn.commitments.length];
        if (!((vk.alpha1.x != 0))) revert keyNotSet();
        uint256 bph = boundParamsHash(txn.boundParams);
        uint256[] memory inputs = new uint256[](((2 + txn.nullifiers.length) + txn.commitments.length));
        inputs[0] = uint256(txn.merkleRoot);
        inputs[1] = uint256(bph);
        for (uint256 inputsIndex0 = 0; inputsIndex0 < txn.nullifiers.length; ++inputsIndex0) {
            inputs[(2 + inputsIndex0)] = uint256(txn.nullifiers[inputsIndex0]);
        }
        for (uint256 inputsIndex1 = 0; inputsIndex1 < txn.commitments.length; ++inputsIndex1) {
            inputs[((2 + txn.nullifiers.length) + inputsIndex1)] = uint256(txn.commitments[inputsIndex1]);
        }
        bool ok = snarkVerify(vk, txn.proof, inputs);
        if (!(ok)) revert proofRejected();
    }

    function verifyOwned(Transaction memory txn) internal view {
        VerifyingKey memory vk = ownedVerificationKeys[txn.nullifiers.length][txn.commitments.length];
        if (!((vk.alpha1.x != 0))) revert keyNotSet();
        uint256 bph = boundParamsHash(txn.boundParams);
        uint256[] memory inputs = new uint256[](((3 + txn.nullifiers.length) + txn.commitments.length));
        inputs[0] = uint256(txn.merkleRoot);
        inputs[1] = uint256(bph);
        for (uint256 inputsIndex0 = 0; inputsIndex0 < txn.nullifiers.length; ++inputsIndex0) {
            inputs[(2 + inputsIndex0)] = uint256(txn.nullifiers[inputsIndex0]);
        }
        for (uint256 inputsIndex1 = 0; inputsIndex1 < txn.commitments.length; ++inputsIndex1) {
            inputs[((2 + txn.nullifiers.length) + inputsIndex1)] = uint256(txn.commitments[inputsIndex1]);
        }
        inputs[(((2 + txn.nullifiers.length) + txn.commitments.length) + 0)] = uint256(txn.boundParams.ownerField);
        bool ok = snarkVerify(vk, txn.proof, inputs);
        if (!(ok)) revert proofRejected();
    }

    function applyTransaction(Transaction memory txn) internal {
        uint256 tn = txn.boundParams.treeNumber;
        if (!((txn.nullifiers.length <= 16))) revert shapeTooLarge();
        for (uint256 nIndex = 0; nIndex < txn.nullifiers.length; ++nIndex) {
            bytes32 n = txn.nullifiers[nIndex];
            nullifiers[tn][n] = true;
        }
        if (!((txn.commitments.length <= 16))) revert shapeTooLarge();
        for (uint256 cIndex = 0; cIndex < txn.commitments.length; ++cIndex) {
            bytes32 c = txn.commitments[cIndex];
            insertLeaf(c);
        }
        emit Transacted(txn.merkleRoot);
    }

    function shield(address token, uint256 amount, bytes32 npk) external {
        address sender = msg.sender;
        address me = address(this);
        FeeRatio memory ratio = feeRatio;
        uint256 num = ratio.num;
        uint256 den = ratio.den;
        if (!(((amount == 0) || (num <= (type(uint256).max / amount))))) revert arithmetic();
        uint256 gross = 0;
        unchecked { gross = (amount * num); }
        if (!((den != 0))) revert invalidFeeRatio();
        uint256 fee = (gross / den);
        if (!((fee <= amount))) revert arithmetic();
        uint256 base = 0;
        unchecked { base = (amount - fee); }
        if (!((base <= 1329227995784915872903807060280344575))) revert valueTooLarge();
        uint120 value = uint120(base);
        uint256 fees = treasuryFees[token];
        uint256 fees1 = 0;
        unchecked { fees1 = (fees + fee); }
        if (!((fees1 >= fees))) revert arithmetic();
        if (!IERC20(token).transferFrom(sender, me, amount)) revert tokenRejected();
        bytes32 commitment = PoseidonT4.poseidon([npk, bytes32(uint256(uint160(token))), bytes32(uint256(value))]);
        insertLeaf(commitment);
        treasuryFees[token] = fees1;
        emit Shielded(commitment, amount);
    }

    function transact(Transaction[] memory batch) external {
        if (!((batch.length <= maxBatch))) revert batchTooLarge();
        for (uint256 txnIndex = 0; txnIndex < batch.length; ++txnIndex) {
            Transaction memory txn = batch[txnIndex];
            if (!((uint256(txn.boundParams.ownerField) == 0))) revert ownerMismatch();
            checkCommon(txn);
            verifyPlain(txn);
        }
        if (!((batch.length <= maxBatch))) revert batchTooLarge();
        for (uint256 txnIndex = 0; txnIndex < batch.length; ++txnIndex) {
            Transaction memory txn = batch[txnIndex];
            applyTransaction(txn);
        }
    }

    function transactOwned(Transaction[] memory batch) external {
        address sender = msg.sender;
        if (!((batch.length <= maxBatch))) revert batchTooLarge();
        for (uint256 txnIndex = 0; txnIndex < batch.length; ++txnIndex) {
            Transaction memory txn = batch[txnIndex];
            if (!((txn.boundParams.ownerField == bytes32(uint256(uint160(sender)))))) revert ownerMismatch();
            checkCommon(txn);
            verifyOwned(txn);
        }
        if (!((batch.length <= maxBatch))) revert batchTooLarge();
        for (uint256 txnIndex = 0; txnIndex < batch.length; ++txnIndex) {
            Transaction memory txn = batch[txnIndex];
            applyTransaction(txn);
        }
    }

    function setFeeRatio(uint128 num, uint128 den) external {
        address sender = msg.sender;
        if (!((sender == feeAdmin))) revert notFeeAdmin();
        if (!((0 < den))) revert invalidFeeRatio();
        if (!((num <= den))) revert invalidFeeRatio();
        uint256 num256 = num;
        uint256 den256 = den;
        if (!(((num256 == 0) || (100 <= (type(uint256).max / num256))))) revert arithmetic();
        uint256 numPct = 0;
        unchecked { numPct = (num256 * 100); }
        if (!(((den256 == 0) || (10 <= (type(uint256).max / den256))))) revert arithmetic();
        uint256 denCap = 0;
        unchecked { denCap = (den256 * 10); }
        if (!((numPct <= denCap))) revert invalidFeeRatio();
        feeRatio = FeeRatio(num, den);
        emit FeeRatioSet(num, den);
    }
}
