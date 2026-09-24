// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test, Vm} from 'forge-std/Test.sol';
import {PrivacyPool} from 'armada/privacy-pool/PrivacyPool.sol';
import {ShieldModule} from 'armada/privacy-pool/modules/ShieldModule.sol';
import {TransactModule} from 'armada/privacy-pool/modules/TransactModule.sol';
import {MerkleModule} from 'armada/privacy-pool/modules/MerkleModule.sol';
import {VerifierModule} from 'armada/privacy-pool/modules/VerifierModule.sol';
import {MockUSDCV2} from 'armada/cctp/MockUSDCV2.sol';
import {MockMessageTransmitterV2, MockTokenMessengerV2} from 'armada/cctp/MockCCTPV2.sol';
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
} from 'src/armada/IArmadaPool.sol';

interface IPoseidonT4 {
    function poseidon(bytes32[3] memory input) external pure returns (bytes32);
}

/**
 * @dev Deploys Armada's real PrivacyPool with the circomlib Poseidon libraries at the addresses
 * linked in foundry.toml. `testingMode` bypasses only the SNARK check: Merkle roots, nullifiers,
 * the adapt-contract check and the unshield preimage hash are enforced as on Sepolia.
 */
abstract contract ArmadaFixture is Test {
    address internal constant POSEIDON_T3 = 0x00000000000000000000000000000000000e0503;
    address internal constant POSEIDON_T4 = 0x00000000000000000000000000000000000E0504;

    bytes32 internal constant SHIELD_EVENT =
        keccak256(
            'Shield(uint256,uint256,(bytes32,(uint8,address,uint256),uint120)[],(bytes32[3],bytes32)[],uint256[])'
        );

    MockUSDCV2 internal usdc;
    PrivacyPool internal privacyPool;
    IArmadaPool internal pool;
    uint256 private nullifierSeed;

    function _deployArmada() internal {
        string memory json = vm.readFile('lib/armada-poc/lib/poseidon_bytecode.json');
        _etchCreationCode(POSEIDON_T3, vm.parseJsonBytes(json, '.PoseidonT3.bytecode'));
        _etchCreationCode(POSEIDON_T4, vm.parseJsonBytes(json, '.PoseidonT4.bytecode'));

        usdc = new MockUSDCV2('Mock USDC', 'USDC');
        MockMessageTransmitterV2 transmitter = new MockMessageTransmitterV2(0, address(this));
        MockTokenMessengerV2 messenger = new MockTokenMessengerV2(
            address(transmitter),
            address(usdc),
            0
        );
        transmitter.setTokenMessenger(address(messenger));

        privacyPool = new PrivacyPool();
        privacyPool.initialize(
            address(new ShieldModule()),
            address(new TransactModule()),
            address(new MerkleModule()),
            address(new VerifierModule()),
            address(messenger),
            address(transmitter),
            address(usdc),
            0,
            address(this),
            payable(address(0xFEE))
        );
        privacyPool.setTestingMode(true);
        pool = IArmadaPool(address(privacyPool));
    }

    /// @dev Shield `value` USDC from `from` into a note for `npk`.
    function _shield(address from, bytes32 npk, uint120 value) internal {
        usdc.mint(from, value);
        vm.startPrank(from);
        usdc.approve(address(pool), value);
        ShieldRequest[] memory requests = new ShieldRequest[](1);
        requests[0] = ShieldRequest({preimage: _usdcNote(npk, value), ciphertext: _ciphertext(npk)});
        pool.shield(requests, address(0));
        vm.stopPrank();
    }

    /**
     * @dev A local unshield of `value` USDC to `recipient`, bound to (`adaptContract`,
     * `adaptParams`). The proof is zero; everything else is what a wallet would submit.
     */
    function _unshield(
        address recipient,
        uint120 value,
        address adaptContract,
        bytes32 adaptParams
    ) internal returns (Transaction[] memory transactions) {
        CommitmentPreimage memory note = _usdcNote(bytes32(uint256(uint160(recipient))), value);
        bytes32[] memory nullifiers = new bytes32[](1);
        nullifiers[0] = bytes32(++nullifierSeed);
        bytes32[] memory commitments = new bytes32[](1);
        commitments[0] = commitmentHash(note);

        transactions = new Transaction[](1);
        transactions[0] = Transaction({
            proof: SnarkProof({
                a: G1Point(0, 0),
                b: G2Point([uint256(0), 0], [uint256(0), 0]),
                c: G1Point(0, 0)
            }),
            merkleRoot: privacyPool.merkleRoot(),
            nullifiers: nullifiers,
            commitments: commitments,
            boundParams: BoundParams({
                treeNumber: uint16(privacyPool.treeNumber()),
                minGasPrice: 0,
                unshield: UnshieldType.NORMAL,
                chainID: uint64(block.chainid),
                adaptContract: adaptContract,
                adaptParams: adaptParams,
                commitmentCiphertext: new CommitmentCiphertext[](0)
            }),
            unshieldPreimage: note
        });
    }

    function commitmentHash(CommitmentPreimage memory note) internal pure returns (bytes32) {
        return
            IPoseidonT4(POSEIDON_T4).poseidon(
                [note.npk, bytes32(uint256(uint160(note.token.tokenAddress))), bytes32(uint256(note.value))]
            );
    }

    function _usdcNote(bytes32 npk, uint120 value) internal view returns (CommitmentPreimage memory) {
        return
            CommitmentPreimage({
                npk: npk,
                token: TokenData({tokenType: TokenType.ERC20, tokenAddress: address(usdc), tokenSubID: 0}),
                value: value
            });
    }

    /// @dev A recognizable stand-in for the note encryption a wallet would produce.
    function _ciphertext(bytes32 npk) internal pure returns (ShieldCiphertext memory) {
        return
            ShieldCiphertext({
                encryptedBundle: [keccak256(abi.encode(npk, 0)), keccak256(abi.encode(npk, 1)), keccak256(abi.encode(npk, 2))],
                shieldKey: keccak256(abi.encode(npk, 'shieldKey'))
            });
    }

    /// @dev The notes the pool shielded, decoded from its Shield events in `logs`.
    function _shieldedNotes(
        Vm.Log[] memory logs
    ) internal view returns (CommitmentPreimage[] memory notes, ShieldCiphertext[] memory ciphertexts) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(pool) || logs[i].topics[0] != SHIELD_EVENT) continue;
            (, , notes, ciphertexts, ) = abi.decode(
                logs[i].data,
                (uint256, uint256, CommitmentPreimage[], ShieldCiphertext[], uint256[])
            );
        }
    }

    function _etchCreationCode(address target, bytes memory creationCode) private {
        address deployed;
        assembly {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0), 'Poseidon deployment failed');
        vm.etch(target, deployed.code);
    }
}
