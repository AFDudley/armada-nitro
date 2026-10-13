// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Script, console2} from 'forge-std/Script.sol';
import {PrivacyPool} from 'armada/privacy-pool/PrivacyPool.sol';
import {MockUSDCV2} from 'armada/cctp/MockUSDCV2.sol';
import {IArmadaPool, Transaction} from 'src/armada/IArmadaPool.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {ConsensusApp} from 'src/nitro/ConsensusApp.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {NitroUtils} from 'src/nitro/libraries/NitroUtils.sol';
import {ArmadaNotes} from '../test/helpers/ArmadaNotes.sol';
import {ChannelStates} from '../test/helpers/ChannelStates.sol';
import {IHubCustodian, IFrostTestSigner} from '../test/helpers/IHubCustodian.sol';
import {RevertingTransferToken} from '../test/helpers/RevertingTransferToken.sol';

/**
 * @notice arn-7de: one-shot setup for `scripts/check-e2e-settle-per-asset.py`. Deploys a fresh
 * local fixturenet-shaped environment (manifest.json + deposits.json + keys, the same shapes
 * `script/FixturenetScenario.s.sol` reads) on a local anvil, with a second channel asset
 * (`RevertingTransferToken`) whose `transfer` always reverts -- so the forced channel
 * `FixturenetScenario.s.sol`'s own `setUpHub`/`openAndChallenge`/`earlySettle`/`settle` steps
 * operate on afterwards is a genuine two-asset channel.
 *
 * Deliberately NOT exercising the Railgun engine/real-proof path `env/gates/nitro-e2e/prepare.ts`
 * uses: this builds the channel's funding unshield the same zero-proof way
 * `script/LocalScenario.s.sol` does (`ArmadaNotes.unshield`, pool `testingMode` bypasses the SNARK
 * check), writing its calldata to deposits.json instead of broadcasting it immediately, so
 * `FixturenetScenario.s.sol`'s unmodified `_fund`/`_deposit` helpers can consume it verbatim.
 *
 * Environment: DEPLOYER_KEY, USER_KEY, DELEGATE_KEY, HUB_GROUP_SCALAR, CHALLENGE_DURATION,
 * HUB_REVOCATION_DELAY, MANIFEST_PATH, DEPOSITS_PATH, KEYS_DIR (all share FixturenetScenario's
 * defaults/semantics).
 */
contract CheckSettlePerAssetSetup is Script {
    uint256 internal constant FORCED_USER = 150e6;
    uint256 internal constant FORCED_HUB = 50e6;
    uint256 internal constant USER_FUNDS = 100e6; // matches FixturenetScenario's `_fund`/HUB_FUNDS pairing
    uint256 internal constant USDC2_SUPPLY = 1_000e6;

    struct Env {
        uint256 deployerKey;
        uint256 userKey;
        uint256 groupScalar;
        uint48 challengeDuration;
        uint256 revocationDelay;
        string manifestPath;
        string depositsPath;
        string keysDir;
    }

    struct Deployed {
        PrivacyPool privacyPool;
        MockUSDCV2 usdc;
        RevertingTransferToken usdc2;
        ArmadaNitroAdjudicator adjudicator;
        ConsensusApp consensusApp;
        address custodian;
        address user;
    }

    function run() external {
        require(block.chainid == 31337, 'local anvil only');
        Env memory e = _env();
        Deployed memory d = _deploy(e);

        // Channel 1 ("forced"): the one FixturenetScenario's openAndChallenge/earlySettle/settle
        // operate on. Channel 0 ("cooperative") is never driven by this check -- its deposits.json
        // entry only needs to exist so `.deposits[1]` resolves; its content is unused.
        (bytes32 channelId1, uint64 nonce1, bytes memory calldata1) = _buildDeposit(e, d, uint64(1));
        (bytes32 channelId0, uint64 nonce0, bytes memory calldata0) = _buildDeposit(e, d, uint64(2));

        // Fund channel 1 with the second asset directly (MultiAssetHolder.deposit has no access
        // control): the outcome's usdc2 allocations total FORCED_USER + FORCED_HUB, matching USDC's
        // funding below so a successful per-asset transfer would always be able to pay in full.
        vm.startBroadcast(e.deployerKey);
        d.usdc2.approve(address(d.adjudicator), FORCED_USER + FORCED_HUB);
        d.adjudicator.deposit(address(d.usdc2), channelId1, 0, FORCED_USER + FORCED_HUB);
        vm.stopBroadcast();

        _writeManifest(e, d);
        _writeKeys(e);
        _writeDeposits(e, channelId0, nonce0, calldata0, channelId1, nonce1, calldata1);

        console2.log('channel1 (forced)', vm.toString(channelId1));
        console2.log('usdc2', address(d.usdc2));
    }

    function _deploy(Env memory e) internal returns (Deployed memory d) {
        d.user = vm.addr(e.userKey);
        address deployer = vm.addr(e.deployerKey);

        ArmadaNotes.placePoseidon(true);
        vm.startBroadcast(e.deployerKey);
        (d.privacyPool, d.usdc) = ArmadaNotes.deploy(deployer);
        d.usdc2 = new RevertingTransferToken(USDC2_SUPPLY);
        // arn-3d8: the adjudicator only funds configured assets; this scenario's own usdc and
        // usdc2 must both be on the list, the deposit below (and later per-asset settle) rely on it.
        address[] memory assets = new address[](2);
        assets[0] = address(d.usdc);
        assets[1] = address(d.usdc2);
        d.adjudicator = new ArmadaNitroAdjudicator(IArmadaPool(address(d.privacyPool)), assets);
        d.consensusApp = new ConsensusApp();
        vm.stopBroadcast();

        IFrostTestSigner frost = IFrostTestSigner(deployCode('FrostTestSigner.sol:FrostTestSigner'));
        (uint256 gx, uint256 gy) = frost.publicKey(e.groupScalar);
        vm.broadcast(e.deployerKey);
        d.custodian = deployCode('HubCustodian.sol:HubCustodian', abi.encode(gx, gy, e.revocationDelay));
    }

    function _buildDeposit(
        Env memory e,
        Deployed memory d,
        uint64 nonce
    ) internal returns (bytes32 channelId, uint64 channelNonce, bytes memory calldataOut) {
        channelNonce = nonce;
        INitroTypes.FixedPart memory fp = ChannelStates.fixedPart(
            d.user,
            d.custodian,
            channelNonce,
            address(d.consensusApp),
            e.challengeDuration
        );
        channelId = NitroUtils.getChannelId(fp);
        calldataOut = _depositCalldata(e, d, channelId, nonce);
    }

    function _depositCalldata(
        Env memory e,
        Deployed memory d,
        bytes32 channelId,
        uint64 nonce
    ) internal returns (bytes memory) {
        uint120 amount = uint120(USER_FUNDS);
        // Must be < the BN254 scalar field (ShieldModule._validateCommitmentPreimage); a small
        // nonce-derived value is always safely within range.
        bytes32 depositNpk = bytes32(uint256(0x1111) + uint256(nonce));
        vm.broadcast(e.deployerKey);
        d.usdc.mint(d.user, amount);
        vm.startBroadcast(e.userKey);
        d.usdc.approve(address(d.privacyPool), amount);
        IArmadaPool(address(d.privacyPool)).shield(
            ArmadaNotes.shieldRequests(address(d.usdc), depositNpk, amount),
            address(0)
        );
        vm.stopBroadcast();

        Transaction[] memory txs = ArmadaNotes.unshield(
            d.privacyPool,
            address(d.usdc),
            address(d.adjudicator),
            amount,
            address(d.adjudicator),
            d.adjudicator.depositBinding(channelId, 0),
            keccak256(abi.encode(channelId, 'nullifier'))
        );
        return abi.encodeCall(d.adjudicator.depositFromNote, (channelId, 0, txs));
    }

    function _writeManifest(Env memory e, Deployed memory d) internal {
        string memory json = string.concat(
            '{"armada":{"pool":"',
            vm.toString(address(d.privacyPool)),
            '","usdc":"',
            vm.toString(address(d.usdc)),
            '","usdc2":"',
            vm.toString(address(d.usdc2)),
            '"},"armadaNitro":{"adjudicator":"',
            vm.toString(address(d.adjudicator)),
            '","consensusApp":"',
            vm.toString(address(d.consensusApp)),
            '","hubCustodian":"',
            vm.toString(d.custodian),
            '"},"testAccounts":[{"address":"',
            vm.toString(d.user),
            '","privateKeyFile":"user.key"}]}'
        );
        vm.writeFile(e.manifestPath, json);
    }

    function _writeKeys(Env memory e) internal {
        vm.writeFile(string.concat(e.keysDir, '/deployer.key'), vm.toString(e.deployerKey));
        vm.writeFile(string.concat(e.keysDir, '/user.key'), vm.toString(e.userKey));
    }

    function _writeDeposits(
        Env memory e,
        bytes32 channelId0,
        uint64 nonce0,
        bytes memory calldata0,
        bytes32 channelId1,
        uint64 nonce1,
        bytes memory calldata1
    ) internal {
        string memory json = string.concat(
            '{"deposits":[',
            _depositJson(channelId0, nonce0, USER_FUNDS, calldata0),
            ',',
            _depositJson(channelId1, nonce1, USER_FUNDS, calldata1),
            ']}'
        );
        vm.writeFile(e.depositsPath, json);
    }

    function _depositJson(
        bytes32 channelId,
        uint64 channelNonce,
        uint256 amount,
        bytes memory calldataBytes
    ) internal pure returns (string memory) {
        return
            string.concat(
                '{"channelId":"',
                vm.toString(channelId),
                '","channelNonce":"',
                vm.toString(uint256(channelNonce)),
                '","amount":"',
                vm.toString(amount),
                '","calldata":"',
                vm.toString(calldataBytes),
                '"}'
            );
    }

    function _env() internal view returns (Env memory e) {
        e.deployerKey = vm.envUint('DEPLOYER_KEY');
        e.userKey = vm.envUint('USER_KEY');
        e.groupScalar = vm.envUint('HUB_GROUP_SCALAR');
        e.challengeDuration = uint48(vm.envUint('CHALLENGE_DURATION'));
        e.revocationDelay = vm.envUint('HUB_REVOCATION_DELAY');
        e.manifestPath = vm.envOr('MANIFEST_PATH', string('/env/manifest.json'));
        e.depositsPath = vm.envOr('DEPOSITS_PATH', string('/env/nitro-e2e/deposits.json'));
        e.keysDir = vm.envOr('KEYS_DIR', string('/env'));
    }
}
