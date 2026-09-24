// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Script, console2} from 'forge-std/Script.sol';
import {PrivacyPool} from 'armada/privacy-pool/PrivacyPool.sol';
import {MockUSDCV2} from 'armada/cctp/MockUSDCV2.sol';
import {ArmadaNotes} from '../test/helpers/ArmadaNotes.sol';

/**
 * @notice Deploy Armada's PrivacyPool (testing mode: SNARK check off) and a mock USDC on a local
 * anvil node, writing deployments/31337-armada.json. The Poseidon libraries are written to their
 * linked addresses with anvil_setCode.
 *
 *   DEPLOYER_KEY=... forge script script/LocalArmada.s.sol --rpc-url $RPC --broadcast --slow
 */
contract LocalArmada is Script {
    function run() external returns (PrivacyPool privacyPool, MockUSDCV2 usdc) {
        require(block.chainid == 31337, 'local anvil only');
        uint256 deployerKey = vm.envUint('DEPLOYER_KEY');

        ArmadaNotes.placePoseidon(true);
        vm.startBroadcast(deployerKey);
        (privacyPool, usdc) = ArmadaNotes.deploy(vm.addr(deployerKey));
        vm.stopBroadcast();

        string memory key = 'armada';
        vm.serializeAddress(key, 'pool', address(privacyPool));
        string memory json = vm.serializeAddress(key, 'usdc', address(usdc));
        vm.writeJson(json, 'deployments/31337-armada.json');
        console2.log('pool', address(privacyPool));
    }
}
