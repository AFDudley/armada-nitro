// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Script, console2} from 'forge-std/Script.sol';
import {Vm} from 'forge-std/Vm.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {PrivacyPool} from 'armada/privacy-pool/PrivacyPool.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {NitroUtils} from 'src/nitro/libraries/NitroUtils.sol';
import {CommitmentPreimage, IArmadaPool, Transaction} from 'src/armada/IArmadaPool.sol';
import {ArmadaNotes} from '../test/helpers/ArmadaNotes.sol';
import {ChannelStates} from '../test/helpers/ChannelStates.sol';
import {IHubCustodian} from '../test/helpers/IHubCustodian.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';

/// @dev Minimal read of the Armada pool's live-note surface this scenario needs
/// (`PrivacyPool.isLive`). Declared here rather than imported from armada-poc's PrivacyPool
/// because this scenario only needs the read, not the pool's full ABI.
interface IPrivacyPoolLiveRead {
    function isLive(bytes32 commitment) external view returns (bool);
}

/**
 * @notice R2 scenario (d) (docs/tasks/R2-fixturenet-defect-scenarios.md): fund a channel with a
 * real-proof `depositFromNote`, conclude it, then call `transferAllAssets` on it.
 *
 * Lean theorem (operator correction, 2026-10-25): `bulk_transfer_all_assets_effect`
 * (`Safety.lean`, `AFDudley/armada-lean` `adjudicator-model-v4`) REPLACES the superseded
 * `bulk_paths_never_succeed`. The bulk path follows `docs.statechannels.org`'s own documented
 * behaviour (DOC/0080:77): `transferAllAssets` must NOT revert, and its effect must equal
 * `transfer`'s own per-asset owned-spend fold (`bulkTransferFold`): each allocation index is
 * paid in priority order out of the channel's held value (`afford`, `Outcome.lean:185` --
 * `min(allocation.amount, remaining surplus)`, not "in full" unless the channel holds enough),
 * and the held value falls by exactly the total paid. This scenario asserts: the call does not
 * revert; the payout note matches what `afford` gives (here a single payee, so
 * `min(COOPERATIVE_USER, heldValue before the call)`); the held value afterward is exactly
 * `heldValue before - afford`.
 *
 * Expected today: ERROR before the bulk call is ever reached. No client can fund a channel on
 * today's contract -- the funding deposit itself reverts ("Collateral not adjudicator-owned":
 * `env/gates/nitro-e2e/prepare.ts`'s stock railgun SDK derives a Poseidon-hashed note public
 * key, which can never equal the adjudicator's own raw address). This scenario never seeds
 * holdings by any path a real user lacks -- the deposit is trialed (never broadcast) exactly
 * once, through the same `depositFromNote` calldata a client would submit, and the scenario
 * stops and reports ERROR the moment that trial reverts.
 *
 * If funding ever succeeds (post-rewrite), the bulk call is also trialed first (the same
 * no-queue pattern `FixturenetScenario.s.sol`'s `earlySettle` uses) and only broadcast once
 * known not to revert, so a result is always reachable. Departures-found.md item 5/8 (confirmed
 * separately): today's deployed contract does not override `transferAllAssets` or
 * `concludeAndTransferAllAssets`, so the inherited call succeeds through
 * `PoolSpend.mintPayoutCommitmentsNoChannel` with `nullifiers := []` -- no pool debit. Under the
 * corrected theorem this remains a departure for a different reason than before: the call does
 * not revert (now correct), but its effect does not match `bulkTransferFold` (no debit, net
 * value creation), so once funding is possible the conservation assertion here is expected to
 * FAIL, citing item 5/8.
 *
 * Reuses `FixturenetScenario.s.sol`'s channel-funding and signing helpers (same manifest,
 * deposits.json, FROST-signed hub custodian). Run via `forge script --sig 'run()'`.
 *
 * Environment: DELEGATE_KEY, CHALLENGE_DURATION (must match prepare.ts's binding),
 * MANIFEST_PATH (default /env/manifest.json), DEPOSITS_PATH (default
 * /env/nitro-e2e/deposits.json), KEYS_DIR (default /env), FROST_SHARES_DIR (default /env),
 * FROST_SIGNER (default `frost-signer` on PATH).
 */
contract FixturenetR2BulkReverts is Script {
    bytes32 internal constant USER_PAYOUT_NPK = bytes32(uint256(0x3333));
    // Funded solely from the one real-proof depositFromNote (stage 1's 100 USDC channel 0
    // deposit) -- no second, hub-side deposit (same reasoning as FixturenetR2Payout.s.sol).
    uint256 internal constant COOPERATIVE_USER = 100e6;
    uint256 internal constant COOPERATIVE_HUB = 0;

    string internal constant RESULT_FILE = 'deployments/r2-bulk-reverts-result.json';

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
        bytes txCalldata;
    }

    /// @dev Authorize the hub's delegate (FROST-signed). Mirrors FixturenetR2Payout.s.sol's
    /// setUpHub, against this scenario's own result file.
    function setUpHub() external {
        Ctx memory c = _ctx();
        _hubExecute(
            c,
            address(c.custodian),
            abi.encodeCall(IHubCustodian.authorizeDelegate, (vm.addr(c.delegateKey)))
        );
    }

    /// @dev The (d) scenario itself: trial the funding deposit first. If it reverts (today's
    /// real-deposit wall), report ERROR with the real reason and stop -- there is no funded
    /// channel to conclude or bulk-transfer, and this scenario never seeds holdings by any
    /// other path. If it succeeds, conclude, then trial+assert the bulk transferAllAssets call
    /// against bulk_transfer_all_assets_effect.
    function run() external {
        Ctx memory c = _ctx();
        Deposit memory d = _deposit(0);
        (bool funded, string memory depositReason) = _fund(c, d);
        if (!funded) {
            console2.log('deposit reverted:', depositReason);
            _writeError('deposit', depositReason);
            return;
        }

        INitroTypes.FixedPart memory fp = _fixedPart(c, d.channelNonce);
        INitroTypes.VariablePart memory finalState = _state(c, 7, true, COOPERATIVE_USER, COOPERATIVE_HUB);
        INitroTypes.SignedVariablePart memory signedFinal = ChannelStates.signedByBoth(
            c.userKey,
            c.delegateKey,
            fp,
            finalState
        );
        bytes32 channelId = NitroUtils.getChannelId(fp);

        vm.broadcast(c.deployerKey);
        c.adjudicator.conclude(fp, signedFinal);

        _bulkTransfer(c, channelId, finalState.outcome);
    }

    /// @dev `afford`: a single payee paid in priority order out of the channel's held value
    /// (Outcome.lean:185) -- min(allocation amount, held value). Matches
    /// bulk_transfer_all_assets_effect's own fold for this scenario's one-payee outcome.
    function _afford(uint256 allocationAmount, uint256 heldValue) internal pure returns (uint256) {
        return allocationAmount < heldValue ? allocationAmount : heldValue;
    }

    /// @dev Trial the bulk `transferAllAssets` call first (never under vm.broadcast -- the same
    /// no-queue trick FixturenetScenario.s.sol's earlySettle documents). Per
    /// bulk_transfer_all_assets_effect the call must NOT revert, and its effect must equal the
    /// afford-based per-asset fold: the payout note is exactly `afford(COOPERATIVE_USER,
    /// heldValue before)`, and the held value afterward is exactly `heldValue before - afford`.
    function _bulkTransfer(Ctx memory c, bytes32 channelId, Outcome.SingleAssetExit[] memory outcome) internal {
        uint256 heldBefore = c.adjudicator.heldValue(address(c.usdc), channelId);
        uint256 expectedPayout = _afford(COOPERATIVE_USER, heldBefore);

        bytes memory payload = abi.encodeCall(
            c.adjudicator.transferAllAssets,
            (channelId, outcome, bytes32(0))
        );
        (bool ok, bytes memory ret) = address(c.adjudicator).call(payload);
        if (!ok) {
            console2.log('transferAllAssets reverted:', _decodeRevertReason(ret));
            _writeResult(false, true, false, heldBefore, heldBefore, expectedPayout);
            return;
        }

        vm.broadcast(c.deployerKey);
        c.adjudicator.transferAllAssets(channelId, outcome, bytes32(0));

        bool live = _recipientNoteLive(c, expectedPayout);
        uint256 heldAfter = c.adjudicator.heldValue(address(c.usdc), channelId);
        _writeResult(true, false, live, heldBefore, heldAfter, expectedPayout);
    }

    /// @dev The bulk payout mints a fresh commitment -- commitment(destination, asset, amount)
    /// -- for the recipient's npk. Recompute it exactly, then read `pool.isLive` live against
    /// the fixturenet RPC -- never a caller-asserted value.
    function _recipientNoteLive(Ctx memory c, uint256 amount) internal view returns (bool) {
        CommitmentPreimage memory note = ArmadaNotes.usdcNote(address(c.usdc), USER_PAYOUT_NPK, uint120(amount));
        bytes32 commitment = ArmadaNotes.commitmentHash(note);
        return IPrivacyPoolLiveRead(address(c.privacyPool)).isLive(commitment);
    }

    /// @dev Writes the one JSON result line this job's stdout surfaces. PASS iff the call did
    /// not revert, the payout note matching `afford` is live, and the held value fell by
    /// exactly `expectedPayout` (bulkTransferFold's own conservation rule).
    function _writeResult(
        bool bulkBroadcast,
        bool bulkReverted,
        bool liveNote,
        uint256 heldBefore,
        uint256 heldAfter,
        uint256 expectedPayout
    ) internal {
        bool debitMatches = (heldBefore - heldAfter) == expectedPayout;
        bool pass = bulkBroadcast && !bulkReverted && liveNote && debitMatches;
        string memory json = string.concat(
            '{"bulk_broadcast":',
            bulkBroadcast ? 'true' : 'false',
            ',"bulk_reverted":',
            bulkReverted ? 'true' : 'false',
            ',"live_note":',
            liveNote ? 'true' : 'false',
            ',"held_before":',
            vm.toString(heldBefore),
            ',"held_after":',
            vm.toString(heldAfter),
            ',"expected_payout":',
            vm.toString(expectedPayout),
            ',"debit_matches":',
            debitMatches ? 'true' : 'false',
            ',"result":"',
            pass ? 'PASS' : 'FAIL',
            '"}'
        );
        vm.createDir('deployments', true);
        vm.writeFile(RESULT_FILE, json);
        console2.log(json);
    }

    /// @dev Writes the one JSON result line this job's stdout surfaces when the funding deposit
    /// itself reverts, before conclude/transferAllAssets ever run: which stage stopped and the
    /// real decoded revert reason. ERROR means the scenario never reached the bulk call at all.
    function _writeError(string memory stage, string memory reason) internal {
        string memory json = string.concat(
            '{"result":"ERROR","stage":"',
            stage,
            '","reason":"',
            _jsonEscape(reason),
            '"}'
        );
        vm.createDir('deployments', true);
        vm.writeFile(RESULT_FILE, json);
        console2.log(json);
    }

    /// @dev Replaces a double quote with a single quote so a revert reason embeds safely in
    /// this script's own hand-built JSON line (revert strings here never carry a newline).
    function _jsonEscape(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == '"') b[i] = "'";
        }
        return string(b);
    }

    /// @dev Trial `channelId`'s funding deposit first (never under vm.broadcast -- the same
    /// no-queue trick `_bulkTransfer` uses): if it reverts (today's real-deposit wall), return
    /// the decoded reason without ever sending it as a real transaction. If it does not revert,
    /// broadcast it for real. No path other than this real depositFromNote call ever seeds
    /// holdings -- a real user has no other way to fund a channel.
    function _fund(Ctx memory c, Deposit memory d) internal returns (bool ok, string memory reason) {
        bytes memory ret;
        (ok, ret) = address(c.adjudicator).call(d.txCalldata);
        if (!ok) {
            return (false, _decodeRevertReason(ret));
        }
        vm.broadcast(c.userKey);
        (ok, ret) = address(c.adjudicator).call(d.txCalldata);
        if (!ok) {
            return (false, _decodeRevertReason(ret));
        }
        return (true, '');
    }

    /// @dev Sign the operation with FROST shares 1 and 2, then broadcast the group-authorized
    /// `execute`. Mirrors FixturenetScenario.s.sol's `_hubExecute`.
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
        c.frostSharesDir = vm.envOr('FROST_SHARES_DIR', string('/env'));
        c.frostSigner = vm.envOr('FROST_SIGNER', string('frost-signer'));
        c.challengeDuration = uint48(vm.envUint('CHALLENGE_DURATION'));
    }
}
