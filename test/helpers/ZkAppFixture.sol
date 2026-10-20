// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Vm} from 'forge-std/Vm.sol';
import {G1Point, G2Point, SnarkProof, VerifyingKey} from 'armada/privacy-pool/types/PoolTypes.sol';

/// @dev Loads the trivial-circuit ZK fixtures (verification key and Groth16 proof) from the
///      committed JSON files under test/fixtures/zk-app/trivial/. Converts snarkjs point
///      encodings to the pool's G1Point/G2Point conventions (G2 coordinates swapped).
library ZkAppFixture {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));

    /// @dev The trivial circuit's Groth16 verification key from `verification_key.json`.
    function loadTrivialVerifyingKey() internal view returns (VerifyingKey memory) {
        string memory json = vm.readFile('test/fixtures/zk-app/trivial/verification_key.json');

        // The trivial circuit has one public input, so `IC` holds two G1 points (constant term + `y`).
        G1Point[] memory ic = new G1Point[](2);
        ic[0] = G1Point(
            vm.parseJsonUint(json, '.IC[0][0]'),
            vm.parseJsonUint(json, '.IC[0][1]')
        );
        ic[1] = G1Point(
            vm.parseJsonUint(json, '.IC[1][0]'),
            vm.parseJsonUint(json, '.IC[1][1]')
        );

        return VerifyingKey(
            G1Point(
                vm.parseJsonUint(json, '.vk_alpha_1[0]'),
                vm.parseJsonUint(json, '.vk_alpha_1[1]')
            ),
            _g2(json, '.vk_beta_2'),
            _g2(json, '.vk_gamma_2'),
            _g2(json, '.vk_delta_2'),
            ic
        );
    }

    /// @dev The trivial circuit's Groth16 proof from `proof.json`.
    function loadTrivialProof() internal view returns (SnarkProof memory) {
        string memory json = vm.readFile('test/fixtures/zk-app/trivial/proof.json');

        return SnarkProof(
            G1Point(
                vm.parseJsonUint(json, '.pi_a[0]'),
                vm.parseJsonUint(json, '.pi_a[1]')
            ),
            _g2(json, '.pi_b'),
            G1Point(
                vm.parseJsonUint(json, '.pi_c[0]'),
                vm.parseJsonUint(json, '.pi_c[1]')
            )
        );
    }

    /// @dev Reads a snarkjs G2 point `[[a0, a1], [b0, b1], [1, 0]]` and returns the
    ///      G2Point struct with the coordinates swapped to the pool's `[x0, x1] convention.
    function _g2(string memory json, string memory key) private pure returns (G2Point memory) {
        return G2Point(
            [
                vm.parseJsonUint(json, string.concat(key, '[0][1]')),
                vm.parseJsonUint(json, string.concat(key, '[0][0]'))
            ],
            [
                vm.parseJsonUint(json, string.concat(key, '[1][1]')),
                vm.parseJsonUint(json, string.concat(key, '[1][0]'))
            ]
        );
    }
}
