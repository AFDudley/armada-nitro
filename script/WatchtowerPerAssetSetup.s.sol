// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Script, console2} from 'forge-std/Script.sol';
import {PrivacyPool} from 'armada/privacy-pool/PrivacyPool.sol';
import {MockUSDCV2} from 'armada/cctp/MockUSDCV2.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {ConsensusApp} from 'src/nitro/ConsensusApp.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {NitroUtils} from 'src/nitro/libraries/NitroUtils.sol';
import {IArmadaPool, Transaction} from 'src/armada/IArmadaPool.sol';
import {ArmadaNotes} from '../test/helpers/ArmadaNotes.sol';
import {ToggleableERC20} from './helpers/ToggleableERC20.sol';

/**
 * @notice Standalone fixture for `scripts/check-watchtower-respond-per-asset.py` (arn-765): a
 * fresh Armada pool + ArmadaNitroAdjudicator + ConsensusApp on a local anvil node, with a
 * two-asset channel funded between two plain EOAs (asset 0 = real USDC, deposited through the
 * same shield + Groth16-bypassed unshield depositFromNote path as script/LocalScenario.s.sol;
 * asset 1 = a ToggleableERC20 deposited through the plain `deposit` entrypoint). No Railgun SDK,
 * no hardhat: this fixture exists only to exercise WatchtowerScenario.s.sol's `respond(uint256)`
 * fallback (arn-765 / E16 S4), not the real-proof deposit pipeline that armada-watchtower-e2e
 * covers on the shared fixturenet.
 *
 * Writes manifest.json + deposits.json in exactly the shape WatchtowerScenario.s.sol's `_ctx()` /
 * `_deposit()` already expect, so `openAndChallenge`/`respond`/`payoutSince` run unmodified
 * against this fixture; asset 1's address and amount are passed to those calls separately via the
 * SECOND_ASSET / SECOND_ASSET_AMOUNT env vars (see WatchtowerScenario.s.sol's `_withSecondAsset`).
 *
 * Environment: DEPLOYER_KEY, USER_KEY, HUB_KEY, CHALLENGE_DURATION, STATE_N1_USER,
 * HUB_RESERVE, SECOND_ASSET_AMOUNT, MANIFEST_PATH, DEPOSITS_PATH, KEYS_DIR.
 *
 *   forge script script/WatchtowerPerAssetSetup.s.sol --sig "setup(bool)" <reverts> \
 *     --rpc-url $RPC --broadcast
 */
contract WatchtowerPerAssetSetup is Script {
    bytes32 internal constant USER_DEPOSIT_NPK = bytes32(uint256(0x4444));

    struct Cfg {
        uint256 deployerKey;
        uint256 userKey;
        uint256 hubKey;
        uint48 challengeDuration;
        uint256 total;
        uint256 secondAssetAmount;
        bool secondAssetReverts;
    }

    struct Deployed {
        PrivacyPool privacyPool;
        MockUSDCV2 usdc;
        ArmadaNitroAdjudicator adjudicator;
        ConsensusApp consensusApp;
        ToggleableERC20 secondAsset;
    }

    function setup(bool secondAssetReverts) external {
        require(block.chainid == 31337, 'local anvil only');

        uint256 stateN1User = vm.envUint('STATE_N1_USER');
        uint256 hubReserve = vm.envOr('HUB_RESERVE', uint256(500_000));
        Cfg memory cfg = Cfg({
            deployerKey: vm.envUint('DEPLOYER_KEY'),
            userKey: vm.envUint('USER_KEY'),
            hubKey: vm.envUint('HUB_KEY'),
            challengeDuration: uint48(vm.envUint('CHALLENGE_DURATION')),
            // Matches what env/gates/watchtower/prepare.ts funds the real channel with: enough
            // for state N+1's user allocation plus the hub's reserve, since the user funds the
            // whole channel (see WatchtowerScenario.s.sol's header for why).
            total: stateN1User + hubReserve,
            secondAssetAmount: vm.envUint('SECOND_ASSET_AMOUNT'),
            secondAssetReverts: secondAssetReverts
        });

        Deployed memory d = _deployAll(cfg);

        bytes32 channelId = _channelId(cfg, d);
        bytes memory depositCalldata = _fundUsdc(cfg, d, channelId);
        _fundSecondAsset(cfg, d, channelId);

        _writeManifest(cfg, d);
        _writeDeposits(channelId, uint64(block.timestamp), cfg.total, depositCalldata);
        _writeKeys(cfg);

        console2.log('SECOND_ASSET', address(d.secondAsset));
    }

    function _deployAll(Cfg memory cfg) internal returns (Deployed memory d) {
        ArmadaNotes.placePoseidon(true);
        vm.startBroadcast(cfg.deployerKey);
        (d.privacyPool, d.usdc) = ArmadaNotes.deploy(vm.addr(cfg.deployerKey));
        d.secondAsset = new ToggleableERC20();
        // arn-3d8: the adjudicator only funds configured assets; both of this scenario's
        // assets must be on the list, because _fundUsdc and _fundSecondAsset deposit them.
        address[] memory assets = new address[](2);
        assets[0] = address(d.usdc);
        assets[1] = address(d.secondAsset);
        d.adjudicator = new ArmadaNitroAdjudicator(IArmadaPool(address(d.privacyPool)), assets);
        d.consensusApp = new ConsensusApp();
        vm.stopBroadcast();
    }

    function _channelId(Cfg memory cfg, Deployed memory d) internal view returns (bytes32) {
        address[] memory participants = new address[](2);
        participants[0] = vm.addr(cfg.userKey);
        participants[1] = vm.addr(cfg.hubKey);
        return
            NitroUtils.getChannelId(
                INitroTypes.FixedPart({
                    participants: participants,
                    channelNonce: uint64(block.timestamp),
                    appDefinition: address(d.consensusApp),
                    challengeDuration: cfg.challengeDuration
                })
            );
    }

    /// @dev Shields the user's USDC now, but leaves the real deposit (the proved, adjudicator-
    /// bound unshield) as calldata -- openAndChallenge() executes it, unmodified, exactly as the
    /// real fixturenet gate does.
    function _fundUsdc(
        Cfg memory cfg,
        Deployed memory d,
        bytes32 channelId
    ) internal returns (bytes memory depositCalldata) {
        address user = vm.addr(cfg.userKey);

        vm.broadcast(cfg.deployerKey);
        d.usdc.mint(user, uint120(cfg.total));
        vm.startBroadcast(cfg.userKey);
        d.usdc.approve(address(d.privacyPool), cfg.total);
        IArmadaPool(address(d.privacyPool)).shield(
            ArmadaNotes.shieldRequests(address(d.usdc), USER_DEPOSIT_NPK, uint120(cfg.total)),
            address(0)
        );
        vm.stopBroadcast();

        Transaction[] memory txs = ArmadaNotes.unshield(
            d.privacyPool,
            address(d.usdc),
            address(d.adjudicator),
            uint120(cfg.total),
            address(d.adjudicator),
            d.adjudicator.depositBinding(channelId, 0),
            keccak256(abi.encode(channelId, 'usdc'))
        );
        depositCalldata = abi.encodeCall(d.adjudicator.depositFromNote, (channelId, 0, txs));
    }

    /// @dev Funded directly through the plain `deposit` entrypoint (no note/proof involved -- it
    /// is not part of what this check exercises), before flipping the revert switch, so funding
    /// itself never depends on the switch.
    function _fundSecondAsset(Cfg memory cfg, Deployed memory d, bytes32 channelId) internal {
        vm.startBroadcast(cfg.deployerKey);
        d.secondAsset.mint(vm.addr(cfg.deployerKey), cfg.secondAssetAmount);
        d.secondAsset.approve(address(d.adjudicator), cfg.secondAssetAmount);
        d.adjudicator.deposit(address(d.secondAsset), channelId, 0, cfg.secondAssetAmount);
        d.secondAsset.setRejectTransfers(cfg.secondAssetReverts);
        vm.stopBroadcast();
    }

    function _writeManifest(Cfg memory cfg, Deployed memory d) internal {
        string memory armadaObj = string.concat(
            '{"pool":"',
            vm.toString(address(d.privacyPool)),
            '","usdc":"',
            vm.toString(address(d.usdc)),
            '"}'
        );
        string memory armadaNitroObj = string.concat(
            '{"adjudicator":"',
            vm.toString(address(d.adjudicator)),
            '","consensusApp":"',
            vm.toString(address(d.consensusApp)),
            '"}'
        );
        string memory testAccounts = string.concat(
            '[{"address":"',
            vm.toString(vm.addr(cfg.userKey)),
            '","privateKeyFile":"user.key"},{"address":"',
            vm.toString(vm.addr(cfg.hubKey)),
            '","privateKeyFile":"hub.key"}]'
        );
        string memory manifestJson = string.concat(
            '{"armada":',
            armadaObj,
            ',"armadaNitro":',
            armadaNitroObj,
            ',"testAccounts":',
            testAccounts,
            '}'
        );
        vm.writeFile(_manifestPath(), manifestJson);
    }

    function _writeDeposits(
        bytes32 channelId,
        uint64 channelNonce,
        uint256 amount,
        bytes memory depositCalldata
    ) internal {
        string memory depKey = 'deposit0';
        vm.serializeBytes32(depKey, 'channelId', channelId);
        vm.serializeUint(depKey, 'channelNonce', uint256(channelNonce));
        vm.serializeUint(depKey, 'amount', amount);
        string memory depJson = vm.serializeBytes(depKey, 'calldata', depositCalldata);
        vm.writeFile(_depositsPath(), string.concat('{"deposits":[', depJson, ']}'));
    }

    function _writeKeys(Cfg memory cfg) internal {
        string memory keysDir = _keysDir();
        vm.createDir(keysDir, true);
        vm.writeFile(string.concat(keysDir, '/deployer.key'), vm.toString(cfg.deployerKey));
        vm.writeFile(string.concat(keysDir, '/user.key'), vm.toString(cfg.userKey));
        vm.writeFile(string.concat(keysDir, '/hub.key'), vm.toString(cfg.hubKey));
    }

    function _manifestPath() internal view returns (string memory) {
        return vm.envOr('MANIFEST_PATH', string('/env/manifest.json'));
    }

    function _depositsPath() internal view returns (string memory) {
        return vm.envOr('DEPOSITS_PATH', string('/env/watchtower-e2e/deposits.json'));
    }

    function _keysDir() internal view returns (string memory) {
        return vm.envOr('KEYS_DIR', string('/env'));
    }
}
