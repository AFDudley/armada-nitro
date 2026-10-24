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

/// @dev Circle's FiatToken mint, guarded by the minter role the funding module configures for
/// the deployer (env/reconciler/modules/funding.py). Selector-only.
/// @dev Minimal read of the Armada pool's live-note surface this scenario needs
/// (docs/tasks/R2-fixturenet-defect-scenarios.md scenario (a): `PrivacyPool.isLive`/
/// `preimageOf`). Declared here rather than imported from armada-poc's PrivacyPool because
/// this scenario only needs the read, not the pool's full ABI.
interface IPrivacyPoolLiveRead {
    function isLive(bytes32 commitment) external view returns (bool);
}

/**
 * @notice R2 scenario (a) (docs/tasks/R2-fixturenet-defect-scenarios.md): fund a channel with a
 * real-proof `depositFromNote`, conclude it (unanimous signatures, `conclude`), then `transfer`
 * a nonzero allocation to a recipient. Asserts the payout call does not revert and the
 * recipient's note (`commitment(destination, asset, amount)`) is live in the pool
 * (`PrivacyPool.isLive`, read live via the fixturenet RPC -- never a caller-asserted value).
 *
 * Lean theorem: `payout_can_happen` (`Safety.lean` §D, `AFDudley/armada-lean`
 * `adjudicator-model-v4`). Expected to FAIL today on departure item 6 (zero proof):
 * `PoolSpend.mintOwnedCommitments` submits a hard-coded zero Groth16 proof to
 * `transactOwned`; `PrivacyPool.verifyOwned` rejects it under real verification. This
 * contract never reverts the job on that failure: the payout `transfer` call is trialed on a
 * local fork of the live RPC state first (the same pattern `FixturenetScenario.s.sol`'s
 * `earlySettle` uses), and only broadcast once it is known not to revert, so a FAIL report is
 * always reachable even when the real adjudicator rejects the payout.
 *
 * Reuses `FixturenetScenario.s.sol`'s channel-funding and signing helpers (same manifest,
 * deposits.json, FROST-signed hub custodian). Run via `forge script --sig 'run()'`.
 *
 * Environment: DELEGATE_KEY, CHALLENGE_DURATION (must match prepare.ts's binding),
 * MANIFEST_PATH (default /env/manifest.json), DEPOSITS_PATH (default
 * /env/nitro-e2e/deposits.json), KEYS_DIR (default /env), FROST_SHARES_DIR (default /env),
 * FROST_SIGNER (default `frost-signer` on PATH).
 */
contract FixturenetR2Payout is Script {
    bytes32 internal constant USER_PAYOUT_NPK = bytes32(uint256(0x2222));
    // Funded solely from the one real-proof depositFromNote (stage 1's 100 USDC channel 0
    // deposit) -- no second, hub-side deposit. ArmadaNotes.unshield (the helper
    // FixturenetScenario.s.sol's hub top-up uses) always submits a zero Groth16 proof (its own
    // doc comment: "The proof is zero") and is explicitly testing-mode-only; a second, unrelated
    // zero-proof dependency this scenario does not need, since the brief (docs/tasks/
    // R2-fixturenet-defect-scenarios.md scenario (a)) only requires one real-proof deposit. The
    // payout allocates the deposit's full 100 USDC to the recipient (a nonzero allocation) and
    // zero to the hub's destination.
    uint256 internal constant COOPERATIVE_USER = 100e6;
    uint256 internal constant COOPERATIVE_HUB = 0;

    string internal constant RESULT_FILE = 'deployments/r2-payout-result.json';

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

    /// @dev Authorize the hub's delegate (FROST-signed) and stock the custodian. Mirrors
    /// FixturenetScenario.s.sol's setUpHub, against this scenario's own result files.
    /// @dev Authorizes the hub's delegate on the custodian (EIP-1271: `conclude`'s unanimous
    /// signature check validates the custodian participant's signature through
    /// `IHubCustodian.isValidSignature`, which requires an authorized delegate). The custodian
    /// never spends USDC in this scenario (no hub-side deposit), so it needs no stock mint.
    function setUpHub() external {
        Ctx memory c = _ctx();
        _hubExecute(
            c,
            address(c.custodian),
            abi.encodeCall(IHubCustodian.authorizeDelegate, (vm.addr(c.delegateKey)))
        );
    }

    /// @dev The (a) scenario itself: fund, conclude, trial+broadcast the payout, verify the
    /// recipient's note is live, write the one JSON result line this job reads back.
    function run() external {
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
        bytes32 channelId = NitroUtils.getChannelId(fp);

        vm.broadcast(c.deployerKey);
        c.adjudicator.conclude(fp, signedFinal);

        _payout(c, channelId, finalState.outcome);
    }

    /// @dev Trial the payout `transfer` call first (never under vm.broadcast -- the same
    /// no-queue trick FixturenetScenario.s.sol's earlySettle documents): if it reverts
    /// (departure item 6), report FAIL without ever sending it as a real transaction. If it
    /// does not revert, broadcast it for real, then verify the recipient's note is live.
    function _payout(Ctx memory c, bytes32 channelId, Outcome.SingleAssetExit[] memory outcome) internal {
        uint256[] memory all = new uint256[](0);
        bytes memory outcomeBytes = abi.encode(outcome);
        bytes memory payload = abi.encodeCall(
            c.adjudicator.transfer,
            (0, channelId, outcomeBytes, bytes32(0), all)
        );
        (bool ok, bytes memory ret) = address(c.adjudicator).call(payload);
        if (!ok) {
            console2.log('payout transfer reverted:', _decodeRevertReason(ret));
            _writeResult(false, true, false);
            return;
        }

        vm.broadcast(c.deployerKey);
        c.adjudicator.transfer(0, channelId, outcomeBytes, bytes32(0), all);

        bool live = _recipientNoteLive(c, COOPERATIVE_USER);
        _writeResult(true, false, live);
    }

    /// @dev The payout mints a fresh owned commitment -- commitment(destination, asset,
    /// amount) -- for the recipient's npk. Recompute it exactly (ArmadaNotes.commitmentHash
    /// over the same preimage PoolSpend.mintOwnedCommitments would have minted), then read
    /// `pool.isLive` live against the fixturenet RPC -- never a caller-asserted value.
    function _recipientNoteLive(Ctx memory c, uint256 amount) internal view returns (bool) {
        CommitmentPreimage memory note = ArmadaNotes.usdcNote(address(c.usdc), USER_PAYOUT_NPK, uint120(amount));
        bytes32 commitment = ArmadaNotes.commitmentHash(note);
        return IPrivacyPoolLiveRead(address(c.privacyPool)).isLive(commitment);
    }

    /// @dev Writes the one JSON result line this job's stdout surfaces: whether the payout
    /// `transfer` call was sent for real (not reverted on the trial), whether it reverted, and
    /// whether the recipient's note is live in the pool. PASS iff payout_broadcast && live_note.
    function _writeResult(bool payoutBroadcast, bool payoutReverted, bool liveNote) internal {
        bool pass = payoutBroadcast && !payoutReverted && liveNote;
        string memory json = string.concat(
            '{"payout_broadcast":',
            payoutBroadcast ? 'true' : 'false',
            ',"payout_reverted":',
            payoutReverted ? 'true' : 'false',
            ',"live_note":',
            liveNote ? 'true' : 'false',
            ',"result":"',
            pass ? 'PASS' : 'FAIL',
            '"}'
        );
        vm.createDir('deployments', true);
        vm.writeFile(RESULT_FILE, json);
        console2.log(json);
    }

    /// @dev Fund `channelId` from stage 1's real-proof note alone (sent by the test account) --
    /// no second, hub-side deposit (see the COOPERATIVE_USER/COOPERATIVE_HUB comment above).
    function _fund(Ctx memory c, Deposit memory d) internal {
        vm.broadcast(c.userKey);
        (bool ok, bytes memory ret) = address(c.adjudicator).call(d.txCalldata);
        if (!ok) {
            console2.log('deposit reverted:', _decodeRevertReason(ret));
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
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
