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
    error shapeTooLarge();
    error unknownRoot();
    error nullifierSpent();
    error keyNotSet();
    error proofRejected();
    error ownerMismatch();
    error batchTooLarge();
    error notSealed();
    error alreadySealed();
    error keyAlreadySet();
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
    uint256 internal constant EMPTY_TREE_ROOT = 9493149700940509817378043077993653487291699154667385859234945399563579865744;
    uint256 internal constant ZERO_0 = 2051258411002736885948763699317990061539314419500486054347250703186609807356;
    uint256 internal constant ZERO_1 = 798649550954976630491249457249448595186529806442197797936973525980664838735;
    uint256 internal constant ZERO_2 = 3860253447950477476238282376227806265529430782364398060886622632609206263506;
    uint256 internal constant ZERO_3 = 10967393403090576943058612851160624964768856418916757431315467969379265276661;
    uint256 internal constant ZERO_4 = 4177329909171803290170279196019319447087145475250139657920728261184066492383;
    uint256 internal constant ZERO_5 = 9144726083425293457189930182175584375755866170755203037168330473435257599943;
    uint256 internal constant ZERO_6 = 8236371367060628245320813572019740297071112030680295018688014025332724941914;
    uint256 internal constant ZERO_7 = 20704513355749821470300998799414731362245300238021178553122435057113528378476;
    uint256 internal constant ZERO_8 = 16736886623818773524263138779809916105169520362832964900272252437275369959388;
    uint256 internal constant ZERO_9 = 16415580715665869864634788741927065679186058985255106992778939765291984104497;
    uint256 internal constant ZERO_10 = 5715205213015845364387052206849889843188282449933545435544812025608946666822;
    uint256 internal constant ZERO_11 = 11013175031749877081979736330659999751637067247483574805902945041305483682579;
    uint256 internal constant ZERO_12 = 10708260192616993577686743465610377735773279483333447100671640147037242870779;
    uint256 internal constant ZERO_13 = 17708681376628530799996447981717676562184543188562031708516142906406141650368;
    uint256 internal constant ZERO_14 = 3967876508977884960877910167550068853181553556854105674925421366723704424223;
    uint256 internal constant ZERO_15 = 18077967785446169488603147322170139942753858441115263187838141084900323103797;
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
    bool internal poolSealed;
    address internal immutable feeAdmin;
    address internal immutable treasury;
    uint256 internal immutable maxBatch;

    constructor(address feeAdmin_, address treasury_, uint256 maxBatch_, uint128 num, uint128 den) {
        feeAdmin = feeAdmin_;
        treasury = treasury_;
        maxBatch = maxBatch_;
        checkAndSetFeeRatio(num, den);
        merkleRoot = bytes32(uint256(EMPTY_TREE_ROOT));
        rootHistory[0][bytes32(uint256(EMPTY_TREE_ROOT))] = true;
    }

    function insertLeaf(bytes32 leaf) internal {
        uint256 i0 = nextLeafIndex;
        if ((i0 == 65536)) {
            uint256 tn0 = treeNumber;
            uint256 tn1 = 0;
            unchecked { tn1 = (tn0 + 1); }
            if (!((tn1 >= tn0))) revert arithmetic();
            treeNumber = tn1;
            nextLeafIndex = 0;
        }
        uint256 i = nextLeafIndex;
        if (!((2 != 0))) revert arithmetic();
        uint256 idx1 = (i / 2);
        if (!((2 != 0))) revert arithmetic();
        uint256 idx2 = (idx1 / 2);
        if (!((2 != 0))) revert arithmetic();
        uint256 idx3 = (idx2 / 2);
        if (!((2 != 0))) revert arithmetic();
        uint256 idx4 = (idx3 / 2);
        if (!((2 != 0))) revert arithmetic();
        uint256 idx5 = (idx4 / 2);
        if (!((2 != 0))) revert arithmetic();
        uint256 idx6 = (idx5 / 2);
        if (!((2 != 0))) revert arithmetic();
        uint256 idx7 = (idx6 / 2);
        if (!((2 != 0))) revert arithmetic();
        uint256 idx8 = (idx7 / 2);
        if (!((2 != 0))) revert arithmetic();
        uint256 idx9 = (idx8 / 2);
        if (!((2 != 0))) revert arithmetic();
        uint256 idx10 = (idx9 / 2);
        if (!((2 != 0))) revert arithmetic();
        uint256 idx11 = (idx10 / 2);
        if (!((2 != 0))) revert arithmetic();
        uint256 idx12 = (idx11 / 2);
        if (!((2 != 0))) revert arithmetic();
        uint256 idx13 = (idx12 / 2);
        if (!((2 != 0))) revert arithmetic();
        uint256 idx14 = (idx13 / 2);
        if (!((2 != 0))) revert arithmetic();
        uint256 idx15 = (idx14 / 2);
        uint256 lvl0 = 0;
        uint256 lvl1 = 1;
        uint256 lvl2 = 2;
        uint256 lvl3 = 3;
        uint256 lvl4 = 4;
        uint256 lvl5 = 5;
        uint256 lvl6 = 6;
        uint256 lvl7 = 7;
        uint256 lvl8 = 8;
        uint256 lvl9 = 9;
        uint256 lvl10 = 10;
        uint256 lvl11 = 11;
        uint256 lvl12 = 12;
        uint256 lvl13 = 13;
        uint256 lvl14 = 14;
        uint256 lvl15 = 15;
        if (!((lvl0 < filledSubTrees.length))) revert arithmetic();
        bytes32 oldFilled0 = filledSubTrees[lvl0];
        bytes32 leftHash0 = PoseidonT3.poseidon([leaf, bytes32(uint256(ZERO_0))]);
        bytes32 rightHash0 = PoseidonT3.poseidon([oldFilled0, leaf]);
        if (!((lvl0 < filledSubTrees.length))) revert arithmetic();
        filledSubTrees[lvl0] = (((i % 2) == 0) ? leaf : oldFilled0);
        bytes32 cur1 = (((i % 2) == 0) ? leftHash0 : rightHash0);
        if (!((lvl1 < filledSubTrees.length))) revert arithmetic();
        bytes32 oldFilled1 = filledSubTrees[lvl1];
        bytes32 leftHash1 = PoseidonT3.poseidon([cur1, bytes32(uint256(ZERO_1))]);
        bytes32 rightHash1 = PoseidonT3.poseidon([oldFilled1, cur1]);
        if (!((lvl1 < filledSubTrees.length))) revert arithmetic();
        filledSubTrees[lvl1] = (((idx1 % 2) == 0) ? cur1 : oldFilled1);
        bytes32 cur2 = (((idx1 % 2) == 0) ? leftHash1 : rightHash1);
        if (!((lvl2 < filledSubTrees.length))) revert arithmetic();
        bytes32 oldFilled2 = filledSubTrees[lvl2];
        bytes32 leftHash2 = PoseidonT3.poseidon([cur2, bytes32(uint256(ZERO_2))]);
        bytes32 rightHash2 = PoseidonT3.poseidon([oldFilled2, cur2]);
        if (!((lvl2 < filledSubTrees.length))) revert arithmetic();
        filledSubTrees[lvl2] = (((idx2 % 2) == 0) ? cur2 : oldFilled2);
        bytes32 cur3 = (((idx2 % 2) == 0) ? leftHash2 : rightHash2);
        if (!((lvl3 < filledSubTrees.length))) revert arithmetic();
        bytes32 oldFilled3 = filledSubTrees[lvl3];
        bytes32 leftHash3 = PoseidonT3.poseidon([cur3, bytes32(uint256(ZERO_3))]);
        bytes32 rightHash3 = PoseidonT3.poseidon([oldFilled3, cur3]);
        if (!((lvl3 < filledSubTrees.length))) revert arithmetic();
        filledSubTrees[lvl3] = (((idx3 % 2) == 0) ? cur3 : oldFilled3);
        bytes32 cur4 = (((idx3 % 2) == 0) ? leftHash3 : rightHash3);
        if (!((lvl4 < filledSubTrees.length))) revert arithmetic();
        bytes32 oldFilled4 = filledSubTrees[lvl4];
        bytes32 leftHash4 = PoseidonT3.poseidon([cur4, bytes32(uint256(ZERO_4))]);
        bytes32 rightHash4 = PoseidonT3.poseidon([oldFilled4, cur4]);
        if (!((lvl4 < filledSubTrees.length))) revert arithmetic();
        filledSubTrees[lvl4] = (((idx4 % 2) == 0) ? cur4 : oldFilled4);
        bytes32 cur5 = (((idx4 % 2) == 0) ? leftHash4 : rightHash4);
        if (!((lvl5 < filledSubTrees.length))) revert arithmetic();
        bytes32 oldFilled5 = filledSubTrees[lvl5];
        bytes32 leftHash5 = PoseidonT3.poseidon([cur5, bytes32(uint256(ZERO_5))]);
        bytes32 rightHash5 = PoseidonT3.poseidon([oldFilled5, cur5]);
        if (!((lvl5 < filledSubTrees.length))) revert arithmetic();
        filledSubTrees[lvl5] = (((idx5 % 2) == 0) ? cur5 : oldFilled5);
        bytes32 cur6 = (((idx5 % 2) == 0) ? leftHash5 : rightHash5);
        if (!((lvl6 < filledSubTrees.length))) revert arithmetic();
        bytes32 oldFilled6 = filledSubTrees[lvl6];
        bytes32 leftHash6 = PoseidonT3.poseidon([cur6, bytes32(uint256(ZERO_6))]);
        bytes32 rightHash6 = PoseidonT3.poseidon([oldFilled6, cur6]);
        if (!((lvl6 < filledSubTrees.length))) revert arithmetic();
        filledSubTrees[lvl6] = (((idx6 % 2) == 0) ? cur6 : oldFilled6);
        bytes32 cur7 = (((idx6 % 2) == 0) ? leftHash6 : rightHash6);
        if (!((lvl7 < filledSubTrees.length))) revert arithmetic();
        bytes32 oldFilled7 = filledSubTrees[lvl7];
        bytes32 leftHash7 = PoseidonT3.poseidon([cur7, bytes32(uint256(ZERO_7))]);
        bytes32 rightHash7 = PoseidonT3.poseidon([oldFilled7, cur7]);
        if (!((lvl7 < filledSubTrees.length))) revert arithmetic();
        filledSubTrees[lvl7] = (((idx7 % 2) == 0) ? cur7 : oldFilled7);
        bytes32 cur8 = (((idx7 % 2) == 0) ? leftHash7 : rightHash7);
        if (!((lvl8 < filledSubTrees.length))) revert arithmetic();
        bytes32 oldFilled8 = filledSubTrees[lvl8];
        bytes32 leftHash8 = PoseidonT3.poseidon([cur8, bytes32(uint256(ZERO_8))]);
        bytes32 rightHash8 = PoseidonT3.poseidon([oldFilled8, cur8]);
        if (!((lvl8 < filledSubTrees.length))) revert arithmetic();
        filledSubTrees[lvl8] = (((idx8 % 2) == 0) ? cur8 : oldFilled8);
        bytes32 cur9 = (((idx8 % 2) == 0) ? leftHash8 : rightHash8);
        if (!((lvl9 < filledSubTrees.length))) revert arithmetic();
        bytes32 oldFilled9 = filledSubTrees[lvl9];
        bytes32 leftHash9 = PoseidonT3.poseidon([cur9, bytes32(uint256(ZERO_9))]);
        bytes32 rightHash9 = PoseidonT3.poseidon([oldFilled9, cur9]);
        if (!((lvl9 < filledSubTrees.length))) revert arithmetic();
        filledSubTrees[lvl9] = (((idx9 % 2) == 0) ? cur9 : oldFilled9);
        bytes32 cur10 = (((idx9 % 2) == 0) ? leftHash9 : rightHash9);
        if (!((lvl10 < filledSubTrees.length))) revert arithmetic();
        bytes32 oldFilled10 = filledSubTrees[lvl10];
        bytes32 leftHash10 = PoseidonT3.poseidon([cur10, bytes32(uint256(ZERO_10))]);
        bytes32 rightHash10 = PoseidonT3.poseidon([oldFilled10, cur10]);
        if (!((lvl10 < filledSubTrees.length))) revert arithmetic();
        filledSubTrees[lvl10] = (((idx10 % 2) == 0) ? cur10 : oldFilled10);
        bytes32 cur11 = (((idx10 % 2) == 0) ? leftHash10 : rightHash10);
        if (!((lvl11 < filledSubTrees.length))) revert arithmetic();
        bytes32 oldFilled11 = filledSubTrees[lvl11];
        bytes32 leftHash11 = PoseidonT3.poseidon([cur11, bytes32(uint256(ZERO_11))]);
        bytes32 rightHash11 = PoseidonT3.poseidon([oldFilled11, cur11]);
        if (!((lvl11 < filledSubTrees.length))) revert arithmetic();
        filledSubTrees[lvl11] = (((idx11 % 2) == 0) ? cur11 : oldFilled11);
        bytes32 cur12 = (((idx11 % 2) == 0) ? leftHash11 : rightHash11);
        if (!((lvl12 < filledSubTrees.length))) revert arithmetic();
        bytes32 oldFilled12 = filledSubTrees[lvl12];
        bytes32 leftHash12 = PoseidonT3.poseidon([cur12, bytes32(uint256(ZERO_12))]);
        bytes32 rightHash12 = PoseidonT3.poseidon([oldFilled12, cur12]);
        if (!((lvl12 < filledSubTrees.length))) revert arithmetic();
        filledSubTrees[lvl12] = (((idx12 % 2) == 0) ? cur12 : oldFilled12);
        bytes32 cur13 = (((idx12 % 2) == 0) ? leftHash12 : rightHash12);
        if (!((lvl13 < filledSubTrees.length))) revert arithmetic();
        bytes32 oldFilled13 = filledSubTrees[lvl13];
        bytes32 leftHash13 = PoseidonT3.poseidon([cur13, bytes32(uint256(ZERO_13))]);
        bytes32 rightHash13 = PoseidonT3.poseidon([oldFilled13, cur13]);
        if (!((lvl13 < filledSubTrees.length))) revert arithmetic();
        filledSubTrees[lvl13] = (((idx13 % 2) == 0) ? cur13 : oldFilled13);
        bytes32 cur14 = (((idx13 % 2) == 0) ? leftHash13 : rightHash13);
        if (!((lvl14 < filledSubTrees.length))) revert arithmetic();
        bytes32 oldFilled14 = filledSubTrees[lvl14];
        bytes32 leftHash14 = PoseidonT3.poseidon([cur14, bytes32(uint256(ZERO_14))]);
        bytes32 rightHash14 = PoseidonT3.poseidon([oldFilled14, cur14]);
        if (!((lvl14 < filledSubTrees.length))) revert arithmetic();
        filledSubTrees[lvl14] = (((idx14 % 2) == 0) ? cur14 : oldFilled14);
        bytes32 cur15 = (((idx14 % 2) == 0) ? leftHash14 : rightHash14);
        if (!((lvl15 < filledSubTrees.length))) revert arithmetic();
        bytes32 oldFilled15 = filledSubTrees[lvl15];
        bytes32 leftHash15 = PoseidonT3.poseidon([cur15, bytes32(uint256(ZERO_15))]);
        bytes32 rightHash15 = PoseidonT3.poseidon([oldFilled15, cur15]);
        if (!((lvl15 < filledSubTrees.length))) revert arithmetic();
        filledSubTrees[lvl15] = (((idx15 % 2) == 0) ? cur15 : oldFilled15);
        bytes32 cur16 = (((idx15 % 2) == 0) ? leftHash15 : rightHash15);
        merkleRoot = cur16;
        uint256 t = treeNumber;
        rootHistory[t][cur16] = true;
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
        bool isSealed = poolSealed;
        if (!(isSealed)) revert notSealed();
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
        bool isSealed = poolSealed;
        if (!(isSealed)) revert notSealed();
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
        bool isSealed = poolSealed;
        if (!(isSealed)) revert notSealed();
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

    function checkAndSetFeeRatio(uint128 num, uint128 den) internal {
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
    }

    function setFeeRatio(uint128 num, uint128 den) external {
        address sender = msg.sender;
        if (!((sender == feeAdmin))) revert notFeeAdmin();
        checkAndSetFeeRatio(num, den);
        emit FeeRatioSet(num, den);
    }

    function registerKey(ShapedKey memory k) external {
        address sender = msg.sender;
        if (!((sender == feeAdmin))) revert notFeeAdmin();
        bool isSealed = poolSealed;
        if (!(!(isSealed))) revert alreadySealed();
        VerifyingKey memory existing = verificationKeys[k.nullifiers][k.commitments];
        if (!((existing.alpha1.x == 0))) revert keyAlreadySet();
        verificationKeys[k.nullifiers][k.commitments] = k.key;
    }

    function registerOwnedKey(ShapedKey memory k) external {
        address sender = msg.sender;
        if (!((sender == feeAdmin))) revert notFeeAdmin();
        bool isSealed = poolSealed;
        if (!(!(isSealed))) revert alreadySealed();
        VerifyingKey memory existing = ownedVerificationKeys[k.nullifiers][k.commitments];
        if (!((existing.alpha1.x == 0))) revert keyAlreadySet();
        ownedVerificationKeys[k.nullifiers][k.commitments] = k.key;
    }

    function seal() external {
        address sender = msg.sender;
        if (!((sender == feeAdmin))) revert notFeeAdmin();
        bool isSealed = poolSealed;
        if (!(!(isSealed))) revert alreadySealed();
        poolSealed = true;
    }
}
