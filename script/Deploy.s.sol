// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Script, console2} from 'forge-std/Script.sol';
import {NitroRailgunAdjudicator} from 'src/NitroRailgunAdjudicator.sol';
import {ConsensusApp} from 'src/nitro/ConsensusApp.sol';
import {IArmadaPool} from 'src/armada/IArmadaPool.sol';

/**
 * @notice Deploy the adjudicator, ConsensusApp and one hub custodian against an existing Armada
 * pool, and write the addresses to deployments/<chainId>.json.
 *
 * Environment:
 *   ARMADA_POOL            Armada PrivacyPool (Sepolia demo3: 0x5f3324b47b3CFf937BB67C30B362898E193e5216)
 *   HUB_GROUP_KEY_X/Y      the hub's FROST group public key
 *   HUB_REVOCATION_DELAY   seconds; must exceed the challenge duration of the hub's channels
 *
 *   forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --private-key $KEY
 */
contract Deploy is Script {
    function run()
        external
        returns (NitroRailgunAdjudicator adjudicator, ConsensusApp consensusApp, address custodian)
    {
        address pool = vm.envAddress('ARMADA_POOL');
        require(pool.code.length > 0, 'ARMADA_POOL has no code');
        bytes memory custodianArgs = abi.encode(
            vm.envUint('HUB_GROUP_KEY_X'),
            vm.envUint('HUB_GROUP_KEY_Y'),
            vm.envUint('HUB_REVOCATION_DELAY')
        );

        vm.startBroadcast();
        adjudicator = new NitroRailgunAdjudicator(IArmadaPool(pool));
        consensusApp = new ConsensusApp();
        custodian = deployCode('HubCustodian.sol:HubCustodian', custodianArgs);
        vm.stopBroadcast();

        string memory key = 'deployment';
        vm.serializeAddress(key, 'armadaPool', pool);
        vm.serializeAddress(key, 'adjudicator', address(adjudicator));
        vm.serializeAddress(key, 'consensusApp', address(consensusApp));
        string memory json = vm.serializeAddress(key, 'hubCustodian', custodian);
        string memory path = string.concat('deployments/', vm.toString(block.chainid), '.json');
        vm.writeJson(json, path);
        console2.log('wrote', path);
    }
}
