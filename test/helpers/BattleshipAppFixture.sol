// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Vm} from 'forge-std/Vm.sol';
import {G1Point, G2Point, SnarkProof, VerifyingKey} from 'armada/privacy-pool/types/PoolTypes.sol';

/// @dev Loads the N6 Battleship circuit ZK fixtures (verifying key and the chained
///      hit/miss move Groth16 proofs) from the committed JSON under
///      test/fixtures/zk-app/battleship/. Converts snarkjs point encodings to the
///      pool's G1Point/G2Point conventions (G2 coordinates swapped). The vkey and
///      proofs are generated from the Battleship circuit (a hit move and a miss
///      move; miss's prevCommitment chains from hit's nextCommitment).
library BattleshipAppFixture {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));

    /// @dev The Battleship circuit's verifying key from vkey.json. Six public inputs
    ///      (prevCommitment, nextCommitment, boardCommitment, target, result, stake),
    ///      so IC holds 7 G1 points (constant term + 6 public inputs).
    function loadVerifyingKey() internal view returns (VerifyingKey memory) {
        string memory json = vm.readFile('test/fixtures/zk-app/battleship/vkey.json');

        uint256 n = vm.parseJsonUint(json, '.nPublic');
        G1Point[] memory ic = new G1Point[](n + 1);
        for (uint256 i = 0; i < n + 1; i++) {
            ic[i] = G1Point(
                vm.parseJsonUint(json, string.concat('.IC[', vm.toString(i), '][0]')),
                vm.parseJsonUint(json, string.concat('.IC[', vm.toString(i), '][1]'))
            );
        }

        return VerifyingKey(
            '',
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

    /// @dev A move's proof and its six public inputs
    ///      [prevCommitment, nextCommitment, boardCommitment, target, result, stake]
    ///      from the named fixture (hit.json or miss.json):
    ///      {proof: <snarkjs proof>, publicSignals: [..]}.
    function loadMove(string memory file)
        internal
        view
        returns (SnarkProof memory proof, uint256[] memory publicInputs)
    {
        string memory json = vm.readFile(string.concat('test/fixtures/zk-app/battleship/', file));

        proof = SnarkProof(
            G1Point(
                vm.parseJsonUint(json, '.proof.pi_a[0]'),
                vm.parseJsonUint(json, '.proof.pi_a[1]')
            ),
            _g2(json, '.proof.pi_b'),
            G1Point(
                vm.parseJsonUint(json, '.proof.pi_c[0]'),
                vm.parseJsonUint(json, '.proof.pi_c[1]')
            )
        );

        publicInputs = new uint256[](6);
        publicInputs[0] = vm.parseJsonUint(json, '.publicSignals[0]');
        publicInputs[1] = vm.parseJsonUint(json, '.publicSignals[1]');
        publicInputs[2] = vm.parseJsonUint(json, '.publicSignals[2]');
        publicInputs[3] = vm.parseJsonUint(json, '.publicSignals[3]');
        publicInputs[4] = vm.parseJsonUint(json, '.publicSignals[4]');
        publicInputs[5] = vm.parseJsonUint(json, '.publicSignals[5]');
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
