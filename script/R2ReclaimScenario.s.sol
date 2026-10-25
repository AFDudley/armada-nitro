// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {PrivacyPool} from 'armada/privacy-pool/PrivacyPool.sol';
import {ArmadaNitroAdjudicator, SHIELD_ALLOCATION_TYPE} from 'src/ArmadaNitroAdjudicator.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {NitroUtils} from 'src/nitro/libraries/NitroUtils.sol';
import {IMultiAssetHolder} from 'src/nitro/interfaces/IMultiAssetHolder.sol';
import {ArmadaNotes} from '../test/helpers/ArmadaNotes.sol';
import {ChannelStates} from '../test/helpers/ChannelStates.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';

/// @notice R2 scenario (c) (docs/tasks/R2-fixturenet-defect-scenarios.md): conclude a source
/// channel holding a guarantee allocation and its target, then reclaim the guarantee. The pool's
/// total token balance for the reclaimed asset must be the same before and after the reclaim
/// call (Safety.lean `notedValue_conserved`, the reclaim instance).
///
/// Today the scenario is expected to report ERROR, before departure item 2 is ever reached: a
/// confirmed, separate deploy-script gap. `PoolSpend`'s commitment-hash computation
/// delegatecalls a fixed, `foundry.toml`-linked Poseidon library address; `script/Deploy.s.sol`
/// (the real deploy path `env/reconciler/modules/armada_nitro.py` runs) never places real
/// bytecode there, so `reclaim`'s own mint call reverts with "delegatecall to non-contract
/// address ... usually an unliked library" -- confirmed on a real fixturenet trace. Operator
/// ruling (2026-10-25): `PoolSpend` and the adjudicator deploy path are code the rewrite
/// replaces; this scenario is the rewrite's own check that its deploy places every linked
/// library on the real fixturenet.
///
/// `PoolSpend.settleReclaim`'s own doc comment confirms a never-funded target has no prior
/// commitment at all ("Spends the target channel's current commitment (if any; a never-funded
/// target has none)"), so this scenario needs no deposit into either channel: `reclaim`'s own
/// checks (`_apply_reclaim_checks`) never read `holdings`/`heldValue` for either channel --
/// only that both channels are finalized (ForceMove) and the source's outcome carries a
/// guarantee allocation to the target. That keeps this scenario entirely inside the real,
/// audited ForceMove/MultiAssetHolder path with no pool proof of any kind involved, real or
/// bypassed -- there is nothing here for VERIFICATION_BYPASS to skip. `reclaim` is trialed
/// (never a direct Solidity call) so a revert is reported, not a script crash.
///
/// Phases (separate `forge script --sig` calls so the challenge windows are waited out by the
/// job's shell between calls):
///   finalizeTarget  force-move (challenge) a fresh target channel to finalize it
///   finalizeSource  force-move (challenge) a fresh source channel, with a final state holding
///                    a GUARANTEE allocation to the target
///   reclaimReport   read the pool's token balance, trial reclaim, re-read the balance, and
///                    print exactly one JSON result line to stdout:
///                    {"reclaim_called": true, "balance_before": N0, "balance_after": N1,
///                     "guarantee_amount": G, "result": "PASS"|"FAIL",
///                     "cites": "departures-found.md item 2 ..."}
///                    or, if reclaim reverts: {"result": "ERROR", "stage": "reclaim",
///                     "reason": "<decoded revert>"}
///
/// Environment: MANIFEST_PATH (default /env/manifest.json), KEYS_DIR (default /env),
/// CHALLENGE_DURATION, R2_SOURCE_NONCE / R2_TARGET_NONCE (written by finalizeTarget /
/// finalizeSource to deployments/, so reclaimReport reconstructs the identical channel ids).
contract R2ReclaimScenario is Script {
    bytes32 internal constant USER_PAYOUT_NPK = bytes32(uint256(0x2222));

    uint256 internal constant TARGET_USER = 5e6;
    uint256 internal constant TARGET_HUB = 3e6;
    uint256 internal constant GUARANTEE = TARGET_USER + TARGET_HUB; // 8e6
    uint256 internal constant SOURCE_USER = 2e6;
    uint256 internal constant SOURCE_HUB = 2e6;

    string internal constant TARGET_NONCE_FILE = 'deployments/r2-reclaim-target-nonce';
    string internal constant SOURCE_NONCE_FILE = 'deployments/r2-reclaim-source-nonce';

    struct Ctx {
        PrivacyPool privacyPool;
        IERC20 usdc;
        ArmadaNitroAdjudicator adjudicator;
        address consensusApp;
        address user;
        address hub;
        uint256 userKey;
        uint256 hubKey;
        uint48 challengeDuration;
    }

    // ---------------------------------------------------------------- phases

    /// @dev c2: force-move (challenge) a fresh target channel to finalize it. No deposit: a
    /// never-funded target has no prior commitment at all (PoolSpend.settleReclaim's own
    /// doc comment), and reclaim's own checks never read the target's holdings.
    function finalizeTarget() external {
        Ctx memory c = _ctx();
        uint64 nonce = uint64(block.timestamp);
        vm.createDir('deployments', true);
        vm.writeFile(TARGET_NONCE_FILE, vm.toString(nonce));

        INitroTypes.FixedPart memory fp = _fixedPart(c, nonce);
        INitroTypes.VariablePart memory finalState = _targetState(c);
        INitroTypes.SignedVariablePart memory signedFinal = ChannelStates.signedByBoth(
            c.userKey,
            c.hubKey,
            fp,
            finalState
        );
        INitroTypes.Signature memory challengerSig = ChannelStates.challengerSig(c.userKey, fp, finalState);
        vm.broadcast(c.userKey);
        c.adjudicator.challenge(fp, new INitroTypes.SignedVariablePart[](0), signedFinal, challengerSig);
        console2.log('target challenged; finalizesAt = now + challenge window');
    }

    /// @dev c2: force-move (challenge) a fresh source channel to finalize it, with a final
    /// state holding a GUARANTEE allocation to the target channel id.
    function finalizeSource() external {
        Ctx memory c = _ctx();
        uint64 nonce = uint64(block.timestamp) + 1;
        vm.createDir('deployments', true);
        vm.writeFile(SOURCE_NONCE_FILE, vm.toString(nonce));

        INitroTypes.FixedPart memory fp = _fixedPart(c, nonce);
        bytes32 targetChannelId = NitroUtils.getChannelId(_fixedPart(c, _readNonce(TARGET_NONCE_FILE)));
        INitroTypes.VariablePart memory finalState = _sourceState(c, targetChannelId);
        INitroTypes.SignedVariablePart memory signedFinal = ChannelStates.signedByBoth(
            c.userKey,
            c.hubKey,
            fp,
            finalState
        );
        INitroTypes.Signature memory challengerSig = ChannelStates.challengerSig(c.userKey, fp, finalState);
        vm.broadcast(c.userKey);
        c.adjudicator.challenge(fp, new INitroTypes.SignedVariablePart[](0), signedFinal, challengerSig);
        console2.log('source challenged; finalizesAt = now + challenge window');
    }

    /// @dev c2/c3/c4: read the pool's token balance, trial the reclaim call (never a direct
    /// Solidity call -- the same no-queue trick FixturenetR2Payout.s.sol's `_fund`/`_payout`
    /// use -- so a revert is reported, not a script crash), re-read the balance, and print the
    /// single JSON result line. If reclaim reverts, report ERROR with stage="reclaim" and the
    /// real decoded reason -- confirmed on the real fixturenet: PoolSpend's own commitment-hash
    /// computation delegatecalls a fixed, foundry.toml-linked Poseidon library address that
    /// `script/Deploy.s.sol` never places real bytecode at, so every owned-spend operation
    /// (depositFromNote, transfer, reclaim) reverts there -- a deploy-script gap, not
    /// departure item 2's own mint-without-debit logic, which is never reached. Otherwise
    /// report PASS/FAIL on whether the pool's balance for the reclaimed asset is conserved.
    function reclaimReport() external {
        Ctx memory c = _ctx();
        IMultiAssetHolder.ReclaimArgs memory args = _reclaimArgs(c);

        // c2: the pool's total token balance for the reclaimed asset (usdc.balanceOf(pool)).
        uint256 balanceBefore = c.usdc.balanceOf(address(c.privacyPool));

        (bool ok, string memory reason) = _tryReclaim(c, args);
        if (!ok) {
            console2.log('reclaim reverted:', reason);
            _writeError('reclaim', reason);
            return;
        }

        uint256 balanceAfter = c.usdc.balanceOf(address(c.privacyPool));
        _writeReclaimResult(balanceBefore, balanceAfter);
    }

    /// @dev The guarantee: source channel's allocation at index 1 points at the target
    /// channel. Extracted from reclaimReport to keep its own stack frame small (`forge build`
    /// hits "Stack too deep" otherwise).
    function _reclaimArgs(Ctx memory c) internal view returns (IMultiAssetHolder.ReclaimArgs memory) {
        INitroTypes.FixedPart memory sourceFP = _fixedPart(c, _readNonce(SOURCE_NONCE_FILE));
        INitroTypes.FixedPart memory targetFP = _fixedPart(c, _readNonce(TARGET_NONCE_FILE));
        bytes32 targetChannelId = NitroUtils.getChannelId(targetFP);
        INitroTypes.VariablePart memory sourceState = _sourceState(c, targetChannelId);
        INitroTypes.VariablePart memory targetState = _targetState(c);
        return
            IMultiAssetHolder.ReclaimArgs({
                sourceChannelId: NitroUtils.getChannelId(sourceFP),
                fixedPart: sourceFP,
                variablePart: sourceState,
                sourceOutcomeBytes: abi.encode(sourceState.outcome),
                sourceAssetIndex: 0,
                indexOfTargetInSource: 1,
                targetStateHash: NitroUtils.hashState(targetFP, targetState),
                targetOutcomeBytes: abi.encode(targetState.outcome),
                targetAssetIndex: 0
            });
    }

    /// @dev Trial `reclaim` first (never a direct Solidity call -- the same no-queue trick
    /// FixturenetR2Payout.s.sol's `_fund`/`_payout` use -- so a revert is reported, not a
    /// script crash). If it reverts (today's real-fixturenet wall: a fixed, foundry.toml-
    /// linked Poseidon library address `script/Deploy.s.sol` never places real bytecode at),
    /// return the decoded reason without ever sending it as a real transaction. If it does not
    /// revert, broadcast it for real.
    function _tryReclaim(
        Ctx memory c,
        IMultiAssetHolder.ReclaimArgs memory args
    ) internal returns (bool ok, string memory reason) {
        bytes memory payload = abi.encodeCall(c.adjudicator.reclaim, (args));
        bytes memory ret;
        (ok, ret) = address(c.adjudicator).call(payload);
        if (!ok) {
            return (false, _decodeRevertReason(ret));
        }
        vm.broadcast(c.userKey);
        (ok, ret) = address(c.adjudicator).call(payload);
        if (!ok) {
            return (false, _decodeRevertReason(ret));
        }
        return (true, '');
    }

    /// @dev c3: report the verdict. PASS only if balanceAfter == balanceBefore; otherwise FAIL,
    /// citing departures-found.md item 2.
    function _writeReclaimResult(uint256 balanceBefore, uint256 balanceAfter) internal {
        bool conserved = (balanceAfter == balanceBefore);
        string memory verdict = conserved ? 'PASS' : 'FAIL';
        string memory cite = 'departures-found.md item 2: _settleReclaimExit calls PoolSpend.settleReclaim, which mints priorHeld + guaranteeAmount for the target from one input of priorHeld, with no source debit';

        string memory json = string.concat(
            '{"reclaim_called": true, ',
            '"balance_before": ',
            vm.toString(balanceBefore),
            ', "balance_after": ',
            vm.toString(balanceAfter),
            ', "guarantee_amount": ',
            vm.toString(GUARANTEE),
            ', "result": "',
            verdict,
            '", "cites": "',
            cite,
            '"}'
        );
        console2.log(json);
    }

    /// @dev Writes the one JSON result line this job's stdout surfaces when reclaim itself
    /// reverts: which stage stopped and the real decoded revert reason. ERROR means the
    /// scenario never reached departure item 2's own conservation check.
    function _writeError(string memory stage, string memory reason) internal {
        string memory json = string.concat(
            '{"result":"ERROR","stage":"',
            stage,
            '","reason":"',
            _jsonEscape(reason),
            '"}'
        );
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

    function _decodeRevertReason(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 4) return '<no revert reason>';
        bytes memory encoded = new bytes(ret.length - 4);
        for (uint256 i = 0; i < encoded.length; i++) {
            encoded[i] = ret[i + 4];
        }
        return abi.decode(encoded, (string));
    }

    // ---------------------------------------------------------------- states

    /// @dev The target channel's final state: shield the user's payout, simple to the hub.
    function _targetState(Ctx memory c) internal pure returns (INitroTypes.VariablePart memory) {
        Outcome.Allocation[] memory allocations = new Outcome.Allocation[](2);
        allocations[0] = Outcome.Allocation(
            USER_PAYOUT_NPK,
            TARGET_USER,
            SHIELD_ALLOCATION_TYPE,
            abi.encode(ArmadaNotes.ciphertext(USER_PAYOUT_NPK))
        );
        allocations[1] = Outcome.Allocation(
            bytes32(uint256(uint160(c.hub))),
            TARGET_HUB,
            uint8(Outcome.AllocationType.simple),
            ''
        );
        return _vp(c, allocations);
    }

    /// @dev The source (ledger) channel's final state: a GUARANTEE allocation to the target
    /// channel, plus the source's own simple allocations to its two payees (the guarantee's
    /// metadata names those same two destinations -- compute_reclaim_effects requires both to
    /// be present as plain simple allocations in the source).
    function _sourceState(
        Ctx memory c,
        bytes32 targetChannelId
    ) internal pure returns (INitroTypes.VariablePart memory) {
        bytes32 leftDest = bytes32(uint256(uint160(c.user)));
        bytes32 rightDest = bytes32(uint256(uint160(c.hub)));
        Outcome.Allocation[] memory allocations = new Outcome.Allocation[](3);
        allocations[0] = Outcome.Allocation(leftDest, SOURCE_USER, uint8(Outcome.AllocationType.simple), '');
        allocations[1] = Outcome.Allocation(
            targetChannelId,
            GUARANTEE,
            uint8(Outcome.AllocationType.guarantee),
            abi.encode(leftDest, rightDest)
        );
        allocations[2] = Outcome.Allocation(rightDest, SOURCE_HUB, uint8(Outcome.AllocationType.simple), '');
        return _vp(c, allocations);
    }

    function _vp(
        Ctx memory c,
        Outcome.Allocation[] memory allocations
    ) internal pure returns (INitroTypes.VariablePart memory) {
        Outcome.SingleAssetExit[] memory outcome = new Outcome.SingleAssetExit[](1);
        outcome[0] = Outcome.SingleAssetExit({
            asset: address(c.usdc),
            assetMetadata: Outcome.AssetMetadata({assetType: Outcome.AssetType.Default, metadata: ''}),
            allocations: allocations
        });
        return INitroTypes.VariablePart({outcome: outcome, appData: '', turnNum: 0, isFinal: false});
    }

    // ---------------------------------------------------------------- helpers

    function _fixedPart(Ctx memory c, uint64 channelNonce) internal view returns (INitroTypes.FixedPart memory) {
        address[] memory participants = new address[](2);
        participants[0] = c.user;
        participants[1] = c.hub;
        return
            INitroTypes.FixedPart({
                participants: participants,
                channelNonce: channelNonce,
                appDefinition: c.consensusApp,
                challengeDuration: c.challengeDuration
            });
    }

    function _readNonce(string memory path) internal view returns (uint64) {
        return uint64(vm.parseUint(vm.readFile(path)));
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
        c.user = vm.parseJsonAddress(manifest, '.testAccounts[0].address');
        c.hub = vm.parseJsonAddress(manifest, '.testAccounts[1].address');

        string memory keysDir = vm.envOr('KEYS_DIR', string('/env'));
        string memory userKeyFile = vm.parseJsonString(manifest, '.testAccounts[0].privateKeyFile');
        c.userKey = vm.parseUint(vm.readFile(string.concat(keysDir, '/', userKeyFile)));
        string memory hubKeyFile = vm.parseJsonString(manifest, '.testAccounts[1].privateKeyFile');
        c.hubKey = vm.parseUint(vm.readFile(string.concat(keysDir, '/', hubKeyFile)));
        c.challengeDuration = uint48(vm.envUint('CHALLENGE_DURATION'));
    }
}
