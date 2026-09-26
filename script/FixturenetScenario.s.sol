// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Script, console2} from 'forge-std/Script.sol';
import {Vm} from 'forge-std/Vm.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {PrivacyPool} from 'armada/privacy-pool/PrivacyPool.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {NitroUtils} from 'src/nitro/libraries/NitroUtils.sol';
import {CommitmentPreimage} from 'src/armada/IArmadaPool.sol';
import {ArmadaNotes} from '../test/helpers/ArmadaNotes.sol';
import {ChannelStates} from '../test/helpers/ChannelStates.sol';
import {IHubCustodian, IFrostTestSigner} from '../test/helpers/IHubCustodian.sol';

/// @dev Circle's FiatToken mint, guarded by the minter role the funding module configures for
/// the deployer (env/reconciler/modules/funding.py). Selector-only -- the real return type
/// (bool) is irrelevant to a `call` we don't decode.
interface IMintableUSDC {
    function mint(address to, uint256 amount) external;
}

/**
 * @notice Stage 2 of the `armada-nitro-e2e` gate: `script/LocalScenario.s.sol`'s cooperative
 * close and force close, against the fixturenet manifest (`/env/manifest.json`) instead of
 * `deployments/31337*.json`, and funded by the real-proof `depositFromNote` calldata stage 1
 * (`env/gates/nitro-e2e/prepare.ts`) wrote to `deposits.json` instead of `ArmadaNotes.unshield`'s
 * testing-mode (zero-proof) notes.
 *
 * Each phase is a separate `forge script --sig` call so the force-close waits out a real
 * challenge window:
 *
 *   setUpHub          authorize the hub's delegate (FROST-signed) and stock the custodian
 *   cooperativeClose  fund channel 0 from deposits.json + custodian, conclude, shield the payout
 *   openAndChallenge  fund channel 1; the user challenges with the latest co-signed state
 *   earlySettle       (E10) attempt transferAllAssets immediately -- must revert: the challenge
 *                      window (ForceMove's `finalizesAt`) has not elapsed, so the channel is not
 *                      yet in ChannelMode.Finalized (StatusManager._mode) and
 *                      MultiAssetHolder._requireChannelFinalized reverts 'Channel not finalized.'
 *   settle            after the window: pay out the challenged outcome
 *   verify            read chain state and Shield logs; revert on any mismatch
 *
 * Environment: DELEGATE_KEY, HUB_GROUP_SCALAR, CHALLENGE_DURATION (must equal the value
 * prepare.ts bound into channel 0/1's adaptParams -- it is part of the channelId hash).
 * MANIFEST_PATH (default /env/manifest.json), DEPOSITS_PATH (default
 * /env/nitro-e2e/deposits.json), KEYS_DIR (default /env -- deployer.key and
 * testAccounts[0].privateKeyFile both live under here).
 */
contract FixturenetScenario is Script {
    bytes32 internal constant USER_PAYOUT_NPK = bytes32(uint256(0x2222));
    uint256 internal constant HUB_STOCK = 1_000e6;
    uint256 internal constant HUB_FUNDS = 100e6;

    uint256 internal constant COOPERATIVE_USER = 130e6;
    uint256 internal constant COOPERATIVE_HUB = 70e6;
    uint256 internal constant FORCED_USER = 150e6;
    uint256 internal constant FORCED_HUB = 50e6;

    string internal constant START_BLOCK = 'deployments/fixturenet-scenario-start-block';
    string internal constant HUB_START_BALANCE = 'deployments/fixturenet-scenario-hub-balance';

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
        uint256 groupScalar;
        uint48 challengeDuration;
    }

    struct Deposit {
        bytes32 channelId;
        uint64 channelNonce;
        uint256 amount;
        bytes txCalldata;
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
        vm.writeFile(START_BLOCK, vm.toString(block.number));
        vm.writeFile(HUB_START_BALANCE, vm.toString(c.usdc.balanceOf(address(c.custodian))));
    }

    function cooperativeClose() external {
        Ctx memory c = _ctx();
        Deposit memory d = _deposit(0);
        _fund(c, d);

        INitroTypes.FixedPart memory fp = _fixedPart(c, d.channelNonce);
        INitroTypes.VariablePart memory finalState = _state(c, 7, true, COOPERATIVE_USER, COOPERATIVE_HUB);
        INitroTypes.SignedVariablePart memory signedFinal = ChannelStates.signedByBoth(
            c.userKey,
            c.delegateKey,
            fp,
            finalState
        );
        vm.broadcast(c.deployerKey);
        c.adjudicator.concludeAndTransferAllAssets(fp, signedFinal);
    }

    function openAndChallenge() external {
        Ctx memory c = _ctx();
        Deposit memory d = _deposit(1);
        _fund(c, d);

        INitroTypes.FixedPart memory fp = _fixedPart(c, d.channelNonce);
        INitroTypes.VariablePart memory latest = _state(c, 12, false, FORCED_USER, FORCED_HUB);
        INitroTypes.SignedVariablePart memory signedLatest = ChannelStates.signedByBoth(
            c.userKey,
            c.delegateKey,
            fp,
            latest
        );
        INitroTypes.Signature memory challengerSig = ChannelStates.challengerSig(c.userKey, fp, latest);
        vm.broadcast(c.userKey);
        c.adjudicator.challenge(
            fp,
            new INitroTypes.SignedVariablePart[](0),
            signedLatest,
            challengerSig
        );
        console2.log('challenge window (s)', c.challengeDuration);
    }

    /// @dev E10: prove the challenge window is enforced, not just present. Attempts the same
    /// `transferAllAssets` call `settle()` makes below, immediately after `openAndChallenge()`
    /// registered the challenge -- i.e. strictly before `finalizesAt` (`block.timestamp` at
    /// challenge time + `challengeDuration`, per `ForceMove.challenge`). `_mode` (StatusManager)
    /// is therefore `Challenge`, not `Finalized`, and `_requireChannelFinalized`
    /// (MultiAssetHolder.sol) must revert 'Channel not finalized.'.
    ///
    /// Deliberately NOT wrapped in `vm.broadcast()`: forge script's `--broadcast` mode replays
    /// every call made under an active broadcast prank as a real transaction in its second
    /// (post-simulation) pass, *whether or not that call reverted during simulation* -- a
    /// reverting low-level `.call()` under `vm.broadcast()` still gets queued and then fails the
    /// replay with "Simulated execution failed.", aborting the whole `forge script` process
    /// before this function's own `require(!ok, ...)` result matters (confirmed by running it
    /// that way first). Left unwrapped, this call executes only against forge's local fork of
    /// the live RPC's current state (the same state `settle()` below will see) and is never
    /// queued for broadcast -- so it faithfully reproduces the real revert without ever
    /// attempting to resend it, and guarantees nothing here touches chain state ahead of
    /// `settle()`.
    function earlySettle() external {
        Ctx memory c = _ctx();
        Deposit memory d = _deposit(1);
        INitroTypes.FixedPart memory fp = _fixedPart(c, d.channelNonce);
        INitroTypes.VariablePart memory latest = _state(c, 12, false, FORCED_USER, FORCED_HUB);
        bytes memory data = abi.encodeCall(
            c.adjudicator.transferAllAssets,
            (NitroUtils.getChannelId(fp), latest.outcome, NitroUtils.hashState(fp, latest))
        );
        (bool ok, bytes memory ret) = address(c.adjudicator).call(data);
        require(!ok, 'early settle unexpectedly succeeded before the challenge window elapsed');
        console2.log('early settle correctly reverted:', _decodeRevertReason(ret));
    }

    function settle() external {
        Ctx memory c = _ctx();
        Deposit memory d = _deposit(1);
        INitroTypes.FixedPart memory fp = _fixedPart(c, d.channelNonce);
        INitroTypes.VariablePart memory latest = _state(c, 12, false, FORCED_USER, FORCED_HUB);
        vm.broadcast(c.deployerKey);
        c.adjudicator.transferAllAssets(
            NitroUtils.getChannelId(fp),
            latest.outcome,
            NitroUtils.hashState(fp, latest)
        );
    }

    function verify() external view {
        Ctx memory c = _ctx();
        Deposit memory d0 = _deposit(0);
        Deposit memory d1 = _deposit(1);
        require(c.adjudicator.holdings(address(c.usdc), d0.channelId) == 0, 'cooperative channel not emptied');
        require(c.adjudicator.holdings(address(c.usdc), d1.channelId) == 0, 'forced channel not emptied');
        require(
            c.usdc.balanceOf(address(c.custodian)) ==
                vm.parseUint(vm.readFile(HUB_START_BALANCE)) -
                    2 *
                    HUB_FUNDS +
                    COOPERATIVE_HUB +
                    FORCED_HUB,
            'custodian balance'
        );

        bytes32[] memory topics = new bytes32[](1);
        topics[0] = ArmadaNotes.SHIELD_EVENT;
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(
            vm.parseUint(vm.readFile(START_BLOCK)),
            block.number,
            address(c.privacyPool),
            topics
        );
        bool cooperativePaid;
        bool forcedPaid;
        for (uint256 i = 0; i < logs.length; i++) {
            (CommitmentPreimage[] memory notes, ) = ArmadaNotes.decodeShield(logs[i].data);
            for (uint256 j = 0; j < notes.length; j++) {
                if (notes[j].npk != USER_PAYOUT_NPK) continue;
                if (notes[j].value == _netOfShieldFee(c, COOPERATIVE_USER)) cooperativePaid = true;
                if (notes[j].value == _netOfShieldFee(c, FORCED_USER)) forcedPaid = true;
            }
        }
        require(cooperativePaid, 'no shielded note for the cooperative close');
        require(forcedPaid, 'no shielded note for the force-close');
        console2.log('verified: both channels paid the user by shielding a note');
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Fund `channelId` from stage 1's real-proof note (sent by the test account, per the
    /// brief), then top up from the custodian.
    function _fund(Ctx memory c, Deposit memory d) internal {
        vm.broadcast(c.userKey);
        (bool ok, bytes memory ret) = address(c.adjudicator).call(d.txCalldata);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }

        _hubExecute(
            c,
            address(c.usdc),
            abi.encodeWithSignature('approve(address,uint256)', address(c.adjudicator), HUB_FUNDS)
        );
        _hubExecute(
            c,
            address(c.adjudicator),
            abi.encodeCall(c.adjudicator.deposit, (address(c.usdc), d.channelId, d.amount, HUB_FUNDS))
        );
    }

    /// @dev Sign with the group key off the broadcast (the signer exists only in simulation).
    function _hubExecute(Ctx memory c, address target, bytes memory data) internal {
        IFrostTestSigner frost = IFrostTestSigner(deployCode('FrostTestSigner.sol:FrostTestSigner'));
        bytes32 message = c.custodian.operationHash(c.custodian.nonce(), target, 0, data);
        (uint256 rx, uint256 ry, uint256 z) = frost.sign(c.groupScalar, message);
        vm.broadcast(c.deployerKey);
        c.custodian.execute(target, 0, data, IHubCustodian.GroupSignature(rx, ry, z));
    }

    /// @dev The adjudicator is not a registered (privileged) shield caller -- no adapterRegistry
    /// is deployed in this environment (E6: no governance) -- so its SHIELD-allocation payouts pay
    /// the pool's live shieldFee (deploy_privacy_pool.ts step 10b: 50 bps) like any other shield,
    /// same inclusive-fee formula as ShieldModule._getFee(amount, true, shieldFee).
    function _netOfShieldFee(Ctx memory c, uint256 amount) internal view returns (uint256) {
        uint256 feeBps = c.privacyPool.shieldFee();
        return amount - (amount * feeBps) / 10_000;
    }

    /// @dev Decode a standard `require(cond, "reason")` revert payload (selector
    /// `Error(string)` = 0x08c379a0 + abi-encoded string). Falls back to a fixed string for any
    /// other shape (e.g. a custom error or an out-of-gas revert with no payload) rather than
    /// reverting itself while reporting a revert.
    function _decodeRevertReason(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 4) return '<no revert reason>';
        bytes memory encoded = new bytes(ret.length - 4);
        for (uint256 i = 0; i < encoded.length; i++) {
            encoded[i] = ret[i + 4];
        }
        return abi.decode(encoded, (string));
    }

    function _fixedPart(Ctx memory c, uint64 channelNonce) internal view returns (INitroTypes.FixedPart memory) {
        return
            ChannelStates.fixedPart(c.user, address(c.custodian), channelNonce, c.consensusApp, c.challengeDuration);
    }

    function _state(
        Ctx memory c,
        uint48 turnNum,
        bool isFinal,
        uint256 userAmount,
        uint256 hubAmount
    ) internal pure returns (INitroTypes.VariablePart memory) {
        return
            ChannelStates.state(address(c.usdc), USER_PAYOUT_NPK, address(c.custodian), turnNum, isFinal, userAmount, hubAmount);
    }

    /// @dev Reads deposits.json entry `index` (written by prepare.ts). channelNonce is not part
    /// of the brief's literal {channelId, amount, calldata} triple but is required here:
    /// NitroUtils.getChannelId hashes (participants, channelNonce, appDefinition,
    /// challengeDuration), and that hash cannot be inverted the other way -- this script must
    /// reconstruct the exact FixedPart prepare.ts's proof committed to, not just its channelId.
    function _deposit(uint256 index) internal view returns (Deposit memory d) {
        string memory json = vm.readFile(_depositsPath());
        string memory base = string.concat('.deposits[', vm.toString(index), ']');
        d.channelId = vm.parseJsonBytes32(json, string.concat(base, '.channelId'));
        d.channelNonce = uint64(vm.parseJsonUint(json, string.concat(base, '.channelNonce')));
        d.amount = vm.parseJsonUint(json, string.concat(base, '.amount'));
        d.txCalldata = vm.parseJsonBytes(json, string.concat(base, '.calldata'));
    }

    function _depositsPath() internal view returns (string memory) {
        return vm.envOr('DEPOSITS_PATH', string('/env/nitro-e2e/deposits.json'));
    }

    function _manifestPath() internal view returns (string memory) {
        return vm.envOr('MANIFEST_PATH', string('/env/manifest.json'));
    }

    function _ctx() internal view returns (Ctx memory c) {
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
        c.groupScalar = vm.envUint('HUB_GROUP_SCALAR');
        c.challengeDuration = uint48(vm.envUint('CHALLENGE_DURATION'));
    }
}
