// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {PrivacyPool} from 'armada/privacy-pool/PrivacyPool.sol';
import {ArmadaNitroAdjudicator, SHIELD_ALLOCATION_TYPE} from 'src/ArmadaNitroAdjudicator.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {NitroUtils} from 'src/nitro/libraries/NitroUtils.sol';
import {IArmadaPool, Transaction} from 'src/armada/IArmadaPool.sol';
import {ArmadaNotes} from '../test/helpers/ArmadaNotes.sol';
import {ChannelStates} from '../test/helpers/ChannelStates.sol';
import {IHubCustodian} from '../test/helpers/IHubCustodian.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';

/// @dev Circle's FiatToken mint, guarded by the minter role funding.py configures for the deployer.
interface IMintableUSDC {
    function mint(address to, uint256 amount) external;
}

/**
 * @notice `armada-disclosure-acceptance` job, stage 2: hops H4 (fund the channel from stage 1's
 * real-proof note), H7 (the wallet and the hub co-sign two channel states -- the state right
 * after the deposit, and the final state after the hub's yield contribution) and H5 (conclude,
 * paying the channel's payout by shielding stage 1's precomputed npk2, with its REAL ciphertext --
 * not a test placeholder, so the owning wallet can recognize and later spend it).
 *
 * Adapted from script/FixturenetScenario.s.sol's `cooperativeClose` (same `_fund` / `_hubExecute`
 * / `_settlePerAsset` pattern, same FROST-signed custodian `execute` calls), for a single channel
 * whose payout destination and ciphertext are read from stage 1's output rather than a hardcoded
 * bytes32 constant and a fake encrypted bundle.
 *
 *   setUpHub      authorize the hub's delegate (FROST-signed) and stock the custodian
 *   fundAndClose  fund the channel (H2+H4), co-sign state0 and state1 (H7), conclude paying the
 *                 user's payout by shielding PAYOUT_NPK (H5); writes channel-states.json
 *
 * Environment: DELEGATE_KEY, CHALLENGE_DURATION (must equal stage 1's -- part of the channelId
 * hash). MANIFEST_PATH (default /env/manifest.json), DISCLOSURE_DIR (default /env/disclosure --
 * reads deposits.json and payout-shield.json from here, writes channel-states.json here).
 * KEYS_DIR (default /env), FROST_SHARES_DIR (default /env), FROST_SIGNER (default frost-signer).
 */
contract DisclosureScenario is Script {
    uint256 internal constant HUB_STOCK = 1_000e6;
    /// @dev The hub's own yield contribution: on top of the user's 100 USDC deposit, the final
    /// state pays the user 120 USDC total (100 + this), and the hub keeps none of it back.
    uint256 internal constant HUB_FUNDS = 20e6;
    uint256 internal constant HUB_FINAL = 0;

    string internal constant HUB_START_BALANCE = 'deployments/disclosure-scenario-hub-balance';

    struct Ctx {
        PrivacyPool privacyPool;
        IERC20 usdc;
        ArmadaNitroAdjudicator adjudicator;
        address consensusApp;
        IHubCustodian custodian;
        address user;
        uint256 deployerKey;
        uint256 userKey;
        uint256 delegateKey;
        string frostSharesDir;
        string frostSigner;
        uint48 challengeDuration;
    }

    struct Deposit {
        bytes32 channelId;
        uint64 channelNonce;
        uint256 amount;
    }

    function setUpHub() external {
        Ctx memory c = _ctx();
        _hubExecute(
            c,
            address(c.custodian),
            abi.encodeCall(IHubCustodian.authorizeDelegate, (vm.addr(c.delegateKey)))
        );
        vm.broadcast(c.deployerKey);
        IMintableUSDC(address(c.usdc)).mint(address(c.custodian), HUB_STOCK);
        vm.createDir('deployments', true);
        vm.writeFile(HUB_START_BALANCE, vm.toString(c.usdc.balanceOf(address(c.custodian))));
    }

    function fundAndClose() external {
        Ctx memory c = _ctx();
        Deposit memory d = _deposit();
        bytes memory depositCalldata = vm.parseJsonBytes(
            vm.readFile(_depositsPath()),
            '.calldata'
        );
        _fund(c, d, depositCalldata);

        bytes32 payoutNpk = _payoutNpk();
        bytes memory payoutMetadata = _payoutMetadata();
        INitroTypes.FixedPart memory fp = ChannelStates.fixedPart(
            c.user,
            address(c.custodian),
            d.channelNonce,
            c.consensusApp,
            c.challengeDuration
        );

        // H7, state0: right after the deposit lands, before the hub's yield contribution is
        // attributed to the user. Co-signed, recorded as disclosure evidence -- never submitted
        // on chain (the channel settles with state1 only, like FixturenetScenario's cooperativeClose).
        INitroTypes.VariablePart memory state0 = _state(c, payoutNpk, payoutMetadata, 3, false, d.amount, HUB_FUNDS);
        INitroTypes.SignedVariablePart memory signed0 = ChannelStates.signedByBoth(c.userKey, c.delegateKey, fp, state0);

        // state1: the final, co-signed state -- the hub's yield contribution moves to the user.
        uint256 finalUser = d.amount + HUB_FUNDS;
        INitroTypes.VariablePart memory state1 = _state(c, payoutNpk, payoutMetadata, 7, true, finalUser, HUB_FINAL);
        INitroTypes.SignedVariablePart memory signed1 = ChannelStates.signedByBoth(c.userKey, c.delegateKey, fp, state1);

        vm.broadcast(c.deployerKey);
        c.adjudicator.conclude(fp, signed1);
        bytes32 channelId = NitroUtils.getChannelId(fp);
        _settlePerAsset(c, channelId, state1.outcome, bytes32(0));

        _writeStates(fp, d, payoutNpk, signed0, signed1);
        console2.log('fundAndClose: channel', vm.toString(channelId), 'concluded, payout npk', vm.toString(payoutNpk));
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Fund `channelId` from stage 1's real-proof note (H2+H4), then top up from the
    /// custodian's own shield+unshield (the hub's yield contribution, N1a: note-native only).
    function _fund(Ctx memory c, Deposit memory d, bytes memory depositCalldata) internal {
        vm.broadcast(c.userKey);
        (bool ok, bytes memory ret) = address(c.adjudicator).call(depositCalldata);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }

        bytes32 hubNpk = bytes32(uint256(0x4444) + uint256(uint160(address(c.custodian))));
        _hubExecute(
            c,
            address(c.usdc),
            abi.encodeWithSignature('approve(address,uint256)', address(c.privacyPool), HUB_FUNDS)
        );
        _hubExecute(
            c,
            address(c.privacyPool),
            abi.encodeCall(
                IArmadaPool(address(c.privacyPool)).shield,
                (ArmadaNotes.shieldRequests(address(c.usdc), hubNpk, uint120(HUB_FUNDS)), address(0))
            )
        );
        Transaction[] memory hubTxs = ArmadaNotes.unshield(
            c.privacyPool,
            address(c.usdc),
            address(c.adjudicator),
            uint120(HUB_FUNDS),
            address(c.adjudicator),
            c.adjudicator.depositBinding(d.channelId, d.amount),
            keccak256(abi.encode(d.channelId, 'hub-nullifier')),
            d.amount
        );
        vm.broadcast(c.deployerKey);
        c.adjudicator.depositFromNote(d.channelId, d.amount, hubTxs);
    }

    /// @dev Sign with FROST shares 1 and 2 (`frost-signer sign --format json` via `vm.ffi`),
    /// then broadcast the group-authorized `execute`.
    function _hubExecute(Ctx memory c, address target, bytes memory data) internal {
        bytes32 message = c.custodian.operationHash(c.custodian.nonce(), target, 0, data);
        string[] memory cmd = new string[](9);
        cmd[0] = c.frostSigner;
        cmd[1] = 'sign';
        cmd[2] = '--shares';
        cmd[3] = string.concat(c.frostSharesDir, '/share-1');
        cmd[4] = string.concat(c.frostSharesDir, '/share-2');
        cmd[5] = '--message';
        cmd[6] = vm.toString(message);
        cmd[7] = '--format';
        cmd[8] = 'json';
        string memory json = string(vm.ffi(cmd));
        IHubCustodian.GroupSignature memory sig = IHubCustodian.GroupSignature({
            commitmentX: vm.parseJsonUint(json, '.commitmentX'),
            commitmentY: vm.parseJsonUint(json, '.commitmentY'),
            z: vm.parseJsonUint(json, '.z')
        });
        vm.broadcast(c.deployerKey);
        c.custodian.execute(target, 0, data, sig);
    }

    /// @dev Like FixturenetScenario's `_settlePerAsset`: pay each asset of the outcome through
    /// its own `transfer(assetIndex, ...)` call.
    function _settlePerAsset(
        Ctx memory c,
        bytes32 channelId,
        Outcome.SingleAssetExit[] memory outcome,
        bytes32 stateHash
    ) internal {
        uint256[] memory all = new uint256[](0);
        for (uint256 i = 0; i < outcome.length; i++) {
            bytes memory outcomeBytes = abi.encode(outcome);
            vm.broadcast(c.deployerKey);
            c.adjudicator.transfer(i, channelId, outcomeBytes, stateHash, all);
        }
    }

    /// @dev A state paying `userAmount` to `payoutNpk` (SHIELD, with the REAL ciphertext stage 1
    /// built for that note) and `hubAmount` to the custodian's own address.
    function _state(
        Ctx memory c,
        bytes32 payoutNpk,
        bytes memory payoutMetadata,
        uint48 turnNum,
        bool isFinal,
        uint256 userAmount,
        uint256 hubAmount
    ) internal view returns (INitroTypes.VariablePart memory) {
        Outcome.Allocation[] memory allocations = new Outcome.Allocation[](2);
        allocations[0] = Outcome.Allocation({
            destination: payoutNpk,
            amount: userAmount,
            allocationType: SHIELD_ALLOCATION_TYPE,
            metadata: payoutMetadata
        });
        allocations[1] = Outcome.Allocation({
            destination: bytes32(uint256(uint160(address(c.custodian)))),
            amount: hubAmount,
            allocationType: uint8(Outcome.AllocationType.simple),
            metadata: ''
        });
        Outcome.SingleAssetExit[] memory outcome = new Outcome.SingleAssetExit[](1);
        outcome[0] = Outcome.SingleAssetExit({
            asset: address(c.usdc),
            assetMetadata: Outcome.AssetMetadata({assetType: Outcome.AssetType.Default, metadata: ''}),
            allocations: allocations
        });
        return INitroTypes.VariablePart({outcome: outcome, appData: '', turnNum: turnNum, isFinal: isFinal});
    }

    /// @dev Flat JSON (no serializeJson nesting) -- the disclosure package's H7 evidence.
    /// Split into small helpers, each with few locals, to stay under solc's stack depth limit.
    function _writeStates(
        INitroTypes.FixedPart memory fp,
        Deposit memory d,
        bytes32 payoutNpk,
        INitroTypes.SignedVariablePart memory signed0,
        INitroTypes.SignedVariablePart memory signed1
    ) internal {
        string memory header = _headerJson(fp, d, payoutNpk);
        string memory s0 = _stateJson(signed0);
        string memory s1 = _stateJson(signed1);
        string memory json = string.concat(header, '"state0":', s0, ',"state1":', s1, '}');
        vm.writeFile(string.concat(_disclosureDir(), '/channel-states.json'), json);
    }

    function _headerJson(
        INitroTypes.FixedPart memory fp,
        Deposit memory d,
        bytes32 payoutNpk
    ) internal view returns (string memory) {
        return
            string.concat(
                '{',
                '"channelId":"', vm.toString(NitroUtils.getChannelId(fp)), '",',
                '"fixedPart":{',
                '"participants":["', vm.toString(fp.participants[0]), '","', vm.toString(fp.participants[1]), '"],',
                '"channelNonce":', vm.toString(uint256(fp.channelNonce)), ',',
                '"appDefinition":"', vm.toString(fp.appDefinition), '",',
                '"challengeDuration":', vm.toString(uint256(fp.challengeDuration)),
                '},',
                '"payoutNpk":"', vm.toString(payoutNpk), '",',
                '"depositAmount":', vm.toString(d.amount), ',',
                '"hubYield":', vm.toString(HUB_FUNDS), ','
            );
    }

    function _stateJson(INitroTypes.SignedVariablePart memory signed) internal pure returns (string memory) {
        INitroTypes.VariablePart memory vp = signed.variablePart;
        return
            string.concat(
                '{',
                '"turnNum":', vm.toString(uint256(vp.turnNum)), ',',
                '"isFinal":', vp.isFinal ? 'true' : 'false', ',',
                '"userAmount":', vm.toString(vp.outcome[0].allocations[0].amount), ',',
                '"hubAmount":', vm.toString(vp.outcome[0].allocations[1].amount), ',',
                '"sigs":[', _sigJson(signed.sigs[0]), ',', _sigJson(signed.sigs[1]), ']',
                '}'
            );
    }

    function _sigJson(INitroTypes.Signature memory sig) internal pure returns (string memory) {
        return
            string.concat(
                '{"v":', vm.toString(uint256(sig.v)), ',"r":"', vm.toString(sig.r), '","s":"', vm.toString(sig.s), '"}'
            );
    }

    function _payoutNpk() internal returns (bytes32) {
        return vm.parseJsonBytes32(vm.readFile(_payoutPath()), '.npk');
    }

    /// @dev ABI-encodes src/armada/IArmadaPool.sol's `ShieldCiphertext` from stage 1's real,
    /// wallet-decryptable ciphertext (never ArmadaNotes.ciphertext's deterministic placeholder).
    function _payoutMetadata() internal returns (bytes memory) {
        string memory json = vm.readFile(_payoutPath());
        bytes32[3] memory bundle = [
            vm.parseJsonBytes32(json, '.ciphertext.encryptedBundle[0]'),
            vm.parseJsonBytes32(json, '.ciphertext.encryptedBundle[1]'),
            vm.parseJsonBytes32(json, '.ciphertext.encryptedBundle[2]')
        ];
        bytes32 shieldKey = vm.parseJsonBytes32(json, '.ciphertext.shieldKey');
        return abi.encode(bundle, shieldKey);
    }

    function _deposit() internal returns (Deposit memory d) {
        string memory json = vm.readFile(_depositsPath());
        d.channelId = vm.parseJsonBytes32(json, '.channelId');
        d.channelNonce = uint64(vm.parseJsonUint(json, '.channelNonce'));
        d.amount = vm.parseJsonUint(json, '.amount');
    }

    function _disclosureDir() internal view returns (string memory) {
        return vm.envOr('DISCLOSURE_DIR', string('/env/disclosure'));
    }

    function _depositsPath() internal view returns (string memory) {
        return string.concat(_disclosureDir(), '/deposits.json');
    }

    function _payoutPath() internal view returns (string memory) {
        return string.concat(_disclosureDir(), '/payout-shield.json');
    }

    function _manifestPath() internal view returns (string memory) {
        return vm.envOr('MANIFEST_PATH', string('/env/manifest.json'));
    }

    function _ctx() internal returns (Ctx memory c) {
        string memory manifest = vm.readFile(_manifestPath());
        c.privacyPool = PrivacyPool(payable(vm.parseJsonAddress(manifest, '.armada.pool')));
        c.usdc = IERC20(vm.parseJsonAddress(manifest, '.armada.usdc'));
        c.adjudicator = ArmadaNitroAdjudicator(vm.parseJsonAddress(manifest, '.armadaNitro.adjudicator'));
        c.consensusApp = vm.parseJsonAddress(manifest, '.armadaNitro.consensusApp');
        c.custodian = IHubCustodian(vm.parseJsonAddress(manifest, '.armadaNitro.hubCustodian'));
        c.user = vm.parseJsonAddress(manifest, '.testAccounts[0].address');

        string memory keysDir = vm.envOr('KEYS_DIR', string('/env'));
        c.deployerKey = vm.parseUint(vm.readFile(string.concat(keysDir, '/deployer.key')));
        string memory userKeyFile = vm.parseJsonString(manifest, '.testAccounts[0].privateKeyFile');
        c.userKey = vm.parseUint(vm.readFile(string.concat(keysDir, '/', userKeyFile)));

        c.delegateKey = vm.envUint('DELEGATE_KEY');
        c.frostSharesDir = vm.envOr('FROST_SHARES_DIR', string('/env'));
        c.frostSigner = vm.envOr('FROST_SIGNER', string('frost-signer'));
        c.challengeDuration = uint48(vm.envUint('CHALLENGE_DURATION'));
    }
}
