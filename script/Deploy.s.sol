// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Script, console2} from 'forge-std/Script.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
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
 *   ARMADA_ASSETS          comma-separated token addresses the hub has configured (arn-3d8)
 *
 *   forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --private-key $KEY
 */
contract Deploy is Script {
    function run()
        external
        returns (ArmadaNitroAdjudicator adjudicator, ConsensusApp consensusApp, address custodian)
    {
        address pool = vm.envAddress('ARMADA_POOL');
        require(pool.code.length > 0, 'ARMADA_POOL has no code');
        bytes memory custodianArgs = abi.encode(
            vm.envUint('HUB_GROUP_KEY_X'),
            vm.envUint('HUB_GROUP_KEY_Y'),
            vm.envUint('HUB_REVOCATION_DELAY')
        );

        vm.startBroadcast();
        adjudicator = new ArmadaNitroAdjudicator(IArmadaPool(pool), vm.envAddress("ARMADA_ASSETS", ","));
        consensusApp = new ConsensusApp();
        custodian = deployCode('HubCustodian.sol', custodianArgs);
        vm.stopBroadcast();

        // arn-831: place the foundry-linked Poseidon libraries at their fixed addresses
        // (0x...E0503, 0x...E0504) on the geth fixturenet so the owned-spend ops stop
        // reverting with "delegatecall to non-contract address".
        _placePoseidon();

        string memory key = 'deployment';
        vm.serializeAddress(key, 'armadaPool', pool);
        vm.serializeAddress(key, 'adjudicator', address(adjudicator));
        vm.serializeAddress(key, 'consensusApp', address(consensusApp));
        string memory json = vm.serializeAddress(key, 'hubCustodian', custodian);
        string memory path = string.concat('deployments/', vm.toString(block.chainid), '.json');
        vm.writeJson(json, path);
        console2.log('wrote', path);
    }

    /// @dev Place the circomlib-generated PoseidonT3 and PoseidonT4 bytecode at their foundry.toml-linked
    /// addresses. Reads the bytecode from lib/armada-poc/lib/poseidon_bytecode.json (fs_permissions in
    /// foundry.toml), deploys each to obtain its runtime code, then etches the runtime at the linked
    /// address. The etch is a forge cheat code that writes directly to the chain's state (geth's
    /// state store), not a broadcast transaction.
    function _placePoseidon() private {
        string memory json = vm.readFile('lib/armada-poc/lib/poseidon_bytecode.json');
        _etchPoseidonAt(0x00000000000000000000000000000000000e0503, vm.parseJsonBytes(json, '.PoseidonT3.bytecode'));
        _etchPoseidonAt(0x00000000000000000000000000000000000E0504, vm.parseJsonBytes(json, '.PoseidonT4.bytecode'));
    }

    function _etchPoseidonAt(address target, bytes memory creationCode) private {
        address deployed;
        assembly {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0), 'Poseidon deployment failed');
        bytes memory runtime = deployed.code;
        vm.etch(target, runtime);
        console2.log('etched Poseidon at', vm.toString(target));
    }
}
