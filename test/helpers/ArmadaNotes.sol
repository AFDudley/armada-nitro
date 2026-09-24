// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Vm} from 'forge-std/Vm.sol';
import {PrivacyPool} from 'armada/privacy-pool/PrivacyPool.sol';
import {ShieldModule} from 'armada/privacy-pool/modules/ShieldModule.sol';
import {TransactModule} from 'armada/privacy-pool/modules/TransactModule.sol';
import {MerkleModule} from 'armada/privacy-pool/modules/MerkleModule.sol';
import {VerifierModule} from 'armada/privacy-pool/modules/VerifierModule.sol';
import {MockUSDCV2} from 'armada/cctp/MockUSDCV2.sol';
import {MockMessageTransmitterV2, MockTokenMessengerV2} from 'armada/cctp/MockCCTPV2.sol';
import {
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
 * @dev Notes, unshields and a local Armada deployment, shared by the tests and the local scripts.
 * The Poseidon libraries are Armada's circomlib bytecode at the addresses linked in foundry.toml.
 */
library ArmadaNotes {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));

    address internal constant POSEIDON_T3 = 0x00000000000000000000000000000000000e0503;
    address internal constant POSEIDON_T4 = 0x00000000000000000000000000000000000E0504;
    bytes32 internal constant SHIELD_EVENT =
        keccak256(
            'Shield(uint256,uint256,(bytes32,(uint8,address,uint256),uint120)[],(bytes32[3],bytes32)[],uint256[])'
        );

    /**
     * @dev Put the Poseidon libraries at their linked addresses. With `onAnvil`, also write them to
     * the connected anvil node; a broadcast script calls this before `vm.startBroadcast`.
     */
    function placePoseidon(bool onAnvil) internal {
        string memory json = vm.readFile('lib/armada-poc/lib/poseidon_bytecode.json');
        _place(POSEIDON_T3, vm.parseJsonBytes(json, '.PoseidonT3.bytecode'), onAnvil);
        _place(POSEIDON_T4, vm.parseJsonBytes(json, '.PoseidonT4.bytecode'), onAnvil);
    }

    /**
     * @dev Deploy USDC/CCTP mocks and Armada's PrivacyPool with `testingMode` on (only the SNARK
     * check is bypassed). Requires `placePoseidon` first.
     */
    function deploy(address owner) internal returns (PrivacyPool privacyPool, MockUSDCV2 usdc) {
        usdc = new MockUSDCV2('Mock USDC', 'USDC');
        MockMessageTransmitterV2 transmitter = new MockMessageTransmitterV2(0, owner);
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
            owner,
            payable(address(0xFEE))
        );
        privacyPool.setTestingMode(true);
    }

    function usdcNote(
        address usdc,
        bytes32 npk,
        uint120 value
    ) internal pure returns (CommitmentPreimage memory) {
        return
            CommitmentPreimage({
                npk: npk,
                token: TokenData({tokenType: TokenType.ERC20, tokenAddress: usdc, tokenSubID: 0}),
                value: value
            });
    }

    /// @dev A recognizable stand-in for the note encryption a wallet would produce.
    function ciphertext(bytes32 npk) internal pure returns (ShieldCiphertext memory) {
        return
            ShieldCiphertext({
                encryptedBundle: [
                    keccak256(abi.encode(npk, 0)),
                    keccak256(abi.encode(npk, 1)),
                    keccak256(abi.encode(npk, 2))
                ],
                shieldKey: keccak256(abi.encode(npk, 'shieldKey'))
            });
    }

    function shieldRequests(
        address usdc,
        bytes32 npk,
        uint120 value
    ) internal pure returns (ShieldRequest[] memory requests) {
        requests = new ShieldRequest[](1);
        requests[0] = ShieldRequest({preimage: usdcNote(usdc, npk, value), ciphertext: ciphertext(npk)});
    }

    function commitmentHash(CommitmentPreimage memory note) internal pure returns (bytes32) {
        return
            IPoseidonT4(POSEIDON_T4).poseidon(
                [
                    note.npk,
                    bytes32(uint256(uint160(note.token.tokenAddress))),
                    bytes32(uint256(note.value))
                ]
            );
    }

    /**
     * @dev A local unshield of `value` USDC to `recipient`, bound to (`adaptContract`,
     * `adaptParams`), against the pool's current root. The proof is zero; everything else is what a
     * wallet would submit.
     */
    function unshield(
        PrivacyPool privacyPool,
        address usdc,
        address recipient,
        uint120 value,
        address adaptContract,
        bytes32 adaptParams,
        bytes32 nullifier
    ) internal view returns (Transaction[] memory transactions) {
        CommitmentPreimage memory note = usdcNote(usdc, bytes32(uint256(uint160(recipient))), value);
        bytes32[] memory nullifiers = new bytes32[](1);
        nullifiers[0] = nullifier;
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

    /// @dev Decode one Shield event emitted by `pool`.
    function decodeShield(
        bytes memory data
    ) internal pure returns (CommitmentPreimage[] memory notes, ShieldCiphertext[] memory ciphertexts) {
        (, , notes, ciphertexts, ) = abi.decode(
            data,
            (uint256, uint256, CommitmentPreimage[], ShieldCiphertext[], uint256[])
        );
    }

    /// @dev The notes shielded by the last Shield event from `pool` in `logs`.
    function shieldedNotes(
        Vm.Log[] memory logs,
        address pool
    ) internal pure returns (CommitmentPreimage[] memory notes, ShieldCiphertext[] memory ciphertexts) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != pool || logs[i].topics[0] != SHIELD_EVENT) continue;
            (notes, ciphertexts) = decodeShield(logs[i].data);
        }
    }

    function _place(address target, bytes memory creationCode, bool onAnvil) private {
        address deployed;
        assembly {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0), 'Poseidon deployment failed');
        bytes memory runtime = deployed.code;
        vm.etch(target, runtime);
        if (onAnvil) {
            vm.rpc(
                'anvil_setCode',
                string.concat('["', vm.toString(target), '","', vm.toString(runtime), '"]')
            );
        }
    }
}
