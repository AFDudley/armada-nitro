// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from 'forge-std/Vm.sol';
import {FROSTOffchain, SigningKey} from 'frost-secp256k1-evm/FROSTOffchain.sol';

/**
 * @dev FROST-secp256k1-KECCAK256 signing for tests compiled with solc 0.8.17, which cannot import
 * FROSTOffchain (^0.8.37). Deploy with `deployCode('FrostTestSigner.sol:FrostTestSigner')`.
 */
contract FrostTestSigner {
    using FROSTOffchain for SigningKey;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));

    function publicKey(uint256 scalar) external returns (uint256 x, uint256 y) {
        Vm.Wallet memory wallet = vm.createWallet(scalar);
        return (wallet.publicKeyX, wallet.publicKeyY);
    }

    function sign(
        uint256 scalar,
        bytes32 messageHash
    ) external returns (uint256 commitmentX, uint256 commitmentY, uint256 z) {
        return FROSTOffchain.signingKeyFromScalar(scalar).createSignature(messageHash);
    }
}
