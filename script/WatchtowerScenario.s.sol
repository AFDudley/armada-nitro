// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Script, console2} from 'forge-std/Script.sol';
import {Vm} from 'forge-std/Vm.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';
import {PrivacyPool} from 'armada/privacy-pool/PrivacyPool.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {NitroUtils} from 'src/nitro/libraries/NitroUtils.sol';
import {CommitmentPreimage} from 'src/armada/IArmadaPool.sol';
import {ArmadaNotes} from '../test/helpers/ArmadaNotes.sol';
import {ChannelStates} from '../test/helpers/ChannelStates.sol';

/**
 * @notice `armada-watchtower-e2e` gate (E15): a participant holding a newer co-signed state
 * defeats a stale force-close if its watcher answers within the dispute window, and loses that
 * advantage if it does not.
 *
 * Two channels (index 0 = scenario A, index 1 = scenario B), between two plain EOA participants
 * -- testAccounts[0] ("user") and testAccounts[1] ("hub") -- each real-proof funded entirely by
 * the user (no hub custodian/FROST delegation involved: that machinery (E14, HubCustodian) is
 * orthogonal to what E15 is actually testing -- the ForceMove dispute/response mechanics on a
 * real-proof-funded channel -- and this gate uses two EOAs instead so it does not depend on this
 * shared fixturenet's current custodian delegate/group-key state).
 *
 * Both parties sign state N (turnNum 10, not final, user gets STATE_N_USER) and state N+1
 * (turnNum 11, IS final, user gets STATE_N1_USER > STATE_N_USER). The hub then challenges with
 * the stale state N -- `openAndChallenge`.
 *
 * Scenario A's watcher response is `respond`: it finalizes the channel on the fully-signed,
 * final state N+1 via the payout-free `conclude`, then pays out EVERY asset of the outcome with
 * its own `transfer(assetIndex, ...)` call (E16 S4 / design 15 I5 / arn-5a6) -- one broken
 * asset never blocks payout of the working ones. A channel's second and third assets (if any)
 * are carried via SECOND_ASSET/SECOND_ASSET_AMOUNT and THIRD_ASSET/THIRD_ASSET_AMOUNT below, not
 * through the deposits/manifest files that fund the first asset -- see `_withSecondAsset`.
 *
 * Scenario B skips `respond` entirely; after the window elapses, `settleStale` pays out EVERY
 * asset of the stale challenged state N with its own `transfer(assetIndex, ...)` call (E16 S4 /
 * design 15 I5 / arn-5a6), mirroring script/FixturenetScenario.s.sol's `settle()`.
 *
 * `payoutSince` reads the Shield logs emitted after a recorded start block for a note paid to
 * USER_PAYOUT_NPK and prints its value on a `PAYOUT_LAMPORTS <value>` line for the orchestrating
 * script (stack/scripts/armada-watchtower-e2e.py) to parse.
 *
 * Environment: CHALLENGE_DURATION (must equal the value env/gates/watchtower/prepare.ts bound
 * into both channels' adaptParams), MANIFEST_PATH (default /env/manifest.json), DEPOSITS_PATH
 * (default /env/watchtower-e2e/deposits.json), KEYS_DIR (default /env -- deployer.key and both
 * test accounts' privateKeyFile live under here), STATE_N_USER, STATE_N1_USER, HUB_RESERVE
 * (uint256 base units), SECOND_ASSET (optional: a second asset's token address, added to both
 * channels' outcomes, paid entirely to the hub -- unset/zero means a single-asset outcome, the
 * real fixturenet gate's shape), SECOND_ASSET_AMOUNT (required iff SECOND_ASSET is set).
 */
contract WatchtowerScenario is Script {
    bytes32 internal constant USER_PAYOUT_NPK = bytes32(uint256(0x3333));
    uint48 internal constant TURN_N = 10;
    uint48 internal constant TURN_N1 = 11;

    struct Ctx {
        PrivacyPool privacyPool;
        IERC20 usdc;
        ArmadaNitroAdjudicator adjudicator;
        address consensusApp;
        address user;
        address hub;
        uint256 deployerKey;
        uint256 userKey;
        uint256 hubKey;
        uint48 challengeDuration;
        uint256 stateNUser;
        uint256 stateN1User;
        uint256 total;
        address secondAsset;
        uint256 secondAssetAmount;
        address thirdAsset;
        uint256 thirdAssetAmount;
    }

    struct Deposit {
        bytes32 channelId;
        uint64 channelNonce;
        uint256 amount;
        bytes txCalldata;
    }

    /// @dev Fund channel `index` entirely from its real-proof deposit, then the hub challenges
    /// with the stale, co-signed state N. Records the pre-challenge block so `payoutSince` can
    /// scan only this scenario's Shield logs.
    function openAndChallenge(uint256 index) external {
        Ctx memory c = _ctx();
        Deposit memory d = _deposit(index);

        vm.createDir('deployments', true);
        // +1: excludes anything already mined up to and including this block (e.g. a
        // prior scenario's payout landing in the same block this one is about to read).
        vm.writeFile(_startBlockPath(index), vm.toString(block.number + 1));

        vm.broadcast(c.userKey);
        (bool ok, bytes memory ret) = address(c.adjudicator).call(d.txCalldata);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }

        INitroTypes.FixedPart memory fp = _fixedPart(c, d.channelNonce);
        INitroTypes.VariablePart memory stateN = _stateN(c);
        INitroTypes.SignedVariablePart memory signedN = ChannelStates.signedByBoth(
            c.userKey,
            c.hubKey,
            fp,
            stateN
        );
        INitroTypes.Signature memory challengerSig = ChannelStates.challengerSig(
            c.hubKey,
            fp,
            stateN
        );
        vm.broadcast(c.hubKey);
        c.adjudicator.challenge(
            fp,
            new INitroTypes.SignedVariablePart[](0),
            signedN,
            challengerSig
        );
        console2.log('challenge window (s)', c.challengeDuration);
    }

    /// @dev Scenario A's watcher: answer the stale challenge with the newer, fully-signed, final
    /// state N+1 -- finalizes and pays out immediately, regardless of the outstanding challenge or
    /// how much of the window remains.
    /// @dev Per-asset payout (arn-5a6 / E16 S4 / design 15 I5): the channel is finalized via the
    /// payout-free `conclude`, then EVERY asset of the outcome is paid out one at a time via
    /// `transfer(assetIndex, ...)` -- one broken asset never blocks payout of the working ones.
    /// Each successful `transfer` zeroes that asset's allocations and updates the on-chain
    /// fingerprint (MultiAssetHolder's `_apply_transfer_effects`), so the outcome re-encoded for
    /// the NEXT asset's call must mirror that mutation.
    function respond(uint256 index) external {
        Ctx memory c = _ctx();
        Deposit memory d = _deposit(index);
        INitroTypes.FixedPart memory fp = _fixedPart(c, d.channelNonce);
        INitroTypes.VariablePart memory stateN1 = _stateN1(c);
        INitroTypes.SignedVariablePart memory signedN1 = ChannelStates.signedByBoth(
            c.userKey,
            c.hubKey,
            fp,
            stateN1
        );
        bytes32 channelId = NitroUtils.getChannelId(fp);
        Outcome.SingleAssetExit[] memory outcome = stateN1.outcome;
        uint256[] memory emptyIndices = new uint256[](0);
        bytes memory outcomeBytes = abi.encode(outcome);

        // Finalize the channel on the newer, fully-signed, final state N+1 via the payout-free
        // `conclude`, then pay out every asset of the outcome with its own transfer(assetIndex,
        // ...) call (E16 S4 / design 15 I5 / arn-5a6) -- one broken asset never blocks the
        // working ones. Each successful transfer zeroes that asset's allocations and updates the
        // on-chain fingerprint, so the re-encoded outcome for the NEXT call mirrors that mutation.
        vm.broadcast(c.deployerKey);
        c.adjudicator.conclude(fp, signedN1);
        for (uint256 assetIndex = 0; assetIndex < outcome.length; assetIndex++) {
            vm.broadcast(c.deployerKey);
            // Low-level call (E16 S4 / design 15 I5 / arn-5a6): a broadcast transaction that
            // reverts on-chain fails the whole `forge script` run if called through the typed
            // ABI; routing through `.call()` lets this asset's payout fail on-chain (and still
            // be committed to the broadcast file as its own transfer(assetIndex, ...) call)
            // without blocking payout of the other assets or aborting the script.
            (bool transferOk, ) = address(c.adjudicator).call(
                abi.encodeCall(
                    c.adjudicator.transfer,
                    (assetIndex, channelId, outcomeBytes, bytes32(0), emptyIndices)
                )
            );
            // Only this asset's allocations zero on-chain when its own transfer succeeds; a
            // reverting transfer leaves the fingerprint (and this outcome encoding) unchanged,
            // so the NEXT asset's call must mirror that, not a zeroing that never happened.
            if (transferOk) {
                Outcome.Allocation[] memory allocations = outcome[assetIndex].allocations;
                for (uint256 j = 0; j < allocations.length; j++) {
                    allocations[j].amount = 0;
                }
                outcomeBytes = abi.encode(outcome);
            }
        }
    }

    /// @dev Scenario B: no response arrived; after the challenge window has elapsed, pay out the
    /// stale challenged state N (mirrors script/FixturenetScenario.s.sol's `settle()`).
    /// @dev Single-signer discrimination (E15c): the watcher answers with the newer final state
    /// N+1 signed ONLY by the user (not both parties), so the response reverts on '!unanimous'
    /// in _conclude; scenario A's payout check fails (the note for the user is never paid).
    function respondSingleSigner(uint256 index) external {
        Ctx memory c = _ctx();
        Deposit memory d = _deposit(index);
        INitroTypes.FixedPart memory fp = _fixedPart(c, d.channelNonce);
        INitroTypes.VariablePart memory stateN1 = _stateN1(c);
        INitroTypes.SignedVariablePart memory signedN1 = ChannelStates.signedByUser(
            c.userKey,
            fp,
            stateN1
        );
        vm.broadcast(c.deployerKey);
        c.adjudicator.concludeAndTransferAllAssets(fp, signedN1);
    }

    /// @dev Late-response discrimination (E15c): the watcher answers AFTER the challenge window
    /// has elapsed; the channel is in Challenge mode (not finalized), so a direct
    /// transferAllAssets reverts (channel not finalized) and the payout still equals state N
    /// once the stale challenge settles.
    function respondLate(uint256 index) external {
        Ctx memory c = _ctx();
        Deposit memory d = _deposit(index);
        INitroTypes.FixedPart memory fp = _fixedPart(c, d.channelNonce);
        INitroTypes.VariablePart memory stateN1 = _stateN1(c);
        vm.broadcast(c.deployerKey);
        c.adjudicator.transferAllAssets(
            NitroUtils.getChannelId(fp),
            stateN1.outcome,
            NitroUtils.hashState(fp, stateN1)
        );
    }

    function settleStale(uint256 index) external {
        Ctx memory c = _ctx();
        Deposit memory d = _deposit(index);
        INitroTypes.FixedPart memory fp = _fixedPart(c, d.channelNonce);
        INitroTypes.VariablePart memory stateN = _stateN(c);
        bytes32 channelId = NitroUtils.getChannelId(fp);
        bytes32 stateHash = NitroUtils.hashState(fp, stateN);
        Outcome.SingleAssetExit[] memory outcome = stateN.outcome;
        uint256[] memory emptyIndices = new uint256[](0);
        bytes memory outcomeBytes = abi.encode(outcome);

        // Scenario B: no watcher response; the channel finalized on the stale state N when the
        // challenge window elapsed. Pay out EVERY asset of that state with its own
        // transfer(assetIndex, ...) call -- not only asset index 0 (E16 S4 / design 15 I5 /
        // arn-5a6). One broken asset never blocks payout of the working ones. Each successful
        // transfer zeroes that asset's allocations and updates the on-chain fingerprint
        // (MultiAssetHolder's `_apply_transfer_effects`), so the re-encoded outcome for the NEXT
        // asset's call mirrors that mutation.
        for (uint256 assetIndex = 0; assetIndex < outcome.length; assetIndex++) {
            vm.broadcast(c.deployerKey);
            // Low-level call (E16 S4 / design 15 I5 / arn-5a6): see respond()'s identical
            // comment -- a broken asset's transfer reverting on-chain must not abort the script
            // or block payout of the other assets.
            (bool transferOk, ) = address(c.adjudicator).call(
                abi.encodeCall(
                    c.adjudicator.transfer,
                    (assetIndex, channelId, outcomeBytes, stateHash, emptyIndices)
                )
            );
            // Only this asset's allocations zero on-chain when its own transfer succeeds; a
            // reverting transfer leaves the fingerprint (and this outcome encoding) unchanged,
            // so the NEXT asset's call must mirror that, not a zeroing that never happened.
            if (transferOk) {
                Outcome.Allocation[] memory allocations = outcome[assetIndex].allocations;
                for (uint256 j = 0; j < allocations.length; j++) {
                    allocations[j].amount = 0;
                }
                outcomeBytes = abi.encode(outcome);
            }
        }
    }

    /// @dev Reads the Shield logs emitted since `openAndChallenge(index)`'s recorded start block
    /// for a note paid to USER_PAYOUT_NPK, and prints its value for the orchestrating script.
    /// Reverts if no such note exists (the scenario did not pay the user) or more than one does
    /// (ambiguous -- should never happen: one settlement per channel).
    function payoutSince(uint256 index) external view {
        Ctx memory c = _ctx();
        uint256 startBlock = vm.parseUint(vm.readFile(_startBlockPath(index)));

        bytes32[] memory topics = new bytes32[](1);
        topics[0] = ArmadaNotes.SHIELD_EVENT;
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(
            startBlock,
            block.number,
            address(c.privacyPool),
            topics
        );
        uint256 found = 0;
        uint256 value = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            (CommitmentPreimage[] memory notes, ) = ArmadaNotes.decodeShield(logs[i].data);
            for (uint256 j = 0; j < notes.length; j++) {
                if (notes[j].npk != USER_PAYOUT_NPK) continue;
                found++;
                value = notes[j].value;
            }
        }
        require(found == 1, 'expected exactly one payout note for this scenario');
        console2.log('PAYOUT_LAMPORTS', value);
    }

    // ---------------------------------------------------------------- helpers

    function _fixedPart(Ctx memory c, uint64 channelNonce) internal view returns (INitroTypes.FixedPart memory) {
        return ChannelStates.fixedPart(c.user, c.hub, channelNonce, c.consensusApp, c.challengeDuration);
    }

    function _stateN(Ctx memory c) internal view returns (INitroTypes.VariablePart memory) {
        return
            _withSecondAsset(
                c,
                ChannelStates.state(
                    address(c.usdc),
                    USER_PAYOUT_NPK,
                    c.hub,
                    TURN_N,
                    false,
                    c.stateNUser,
                    c.total - c.stateNUser
                )
            );
    }

    function _stateN1(Ctx memory c) internal view returns (INitroTypes.VariablePart memory) {
        return
            _withSecondAsset(
                c,
                ChannelStates.state(
                    address(c.usdc),
                    USER_PAYOUT_NPK,
                    c.hub,
                    TURN_N1,
                    true,
                    c.stateN1User,
                    c.total - c.stateN1User
                )
            );
    }

    /// @dev Appends a second and/or third asset (SECOND_ASSET/SECOND_ASSET_AMOUNT,
    /// THIRD_ASSET/THIRD_ASSET_AMOUNT), each paid entirely to the hub as a plain
    /// external-destination allocation, to `vp`'s outcome -- a no-op when neither is set, which
    /// is the real fixturenet gate's single-asset shape.
    function _withSecondAsset(
        Ctx memory c,
        INitroTypes.VariablePart memory vp
    ) internal pure returns (INitroTypes.VariablePart memory) {
        bool hasSecond = c.secondAsset != address(0);
        bool hasThird = c.thirdAsset != address(0);
        if (!hasSecond && !hasThird) return vp;

        uint256 numAssets = 1 + (hasSecond ? 1 : 0) + (hasThird ? 1 : 0);
        Outcome.SingleAssetExit[] memory outcome = new Outcome.SingleAssetExit[](numAssets);
        outcome[0] = vp.outcome[0];
        uint256 idx = 1;

        if (hasSecond) {
            Outcome.Allocation[] memory allocations = new Outcome.Allocation[](1);
            allocations[0] = Outcome.Allocation({
                destination: bytes32(uint256(uint160(c.hub))),
                amount: c.secondAssetAmount,
                allocationType: uint8(Outcome.AllocationType.simple),
                metadata: ''
            });
            outcome[idx] = Outcome.SingleAssetExit({
                asset: c.secondAsset,
                assetMetadata: Outcome.AssetMetadata({assetType: Outcome.AssetType.Default, metadata: ''}),
                allocations: allocations
            });
            idx++;
        }
        if (hasThird) {
            Outcome.Allocation[] memory allocations = new Outcome.Allocation[](1);
            allocations[0] = Outcome.Allocation({
                destination: bytes32(uint256(uint160(c.hub))),
                amount: c.thirdAssetAmount,
                allocationType: uint8(Outcome.AllocationType.simple),
                metadata: ''
            });
            outcome[idx] = Outcome.SingleAssetExit({
                asset: c.thirdAsset,
                assetMetadata: Outcome.AssetMetadata({assetType: Outcome.AssetType.Default, metadata: ''}),
                allocations: allocations
            });
        }
        vp.outcome = outcome;
        return vp;
    }
    function _startBlockPath(uint256 index) internal pure returns (string memory) {
        return string.concat('deployments/watchtower-e2e-start-block-', vm.toString(index));
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
        return vm.envOr('DEPOSITS_PATH', string('/env/watchtower-e2e/deposits.json'));
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
        c.deployerKey = vm.parseUint(vm.readFile(string.concat(keysDir, '/deployer.key')));
        string memory userKeyFile = vm.parseJsonString(manifest, '.testAccounts[0].privateKeyFile');
        c.userKey = vm.parseUint(vm.readFile(string.concat(keysDir, '/', userKeyFile)));
        string memory hubKeyFile = vm.parseJsonString(manifest, '.testAccounts[1].privateKeyFile');
        c.hubKey = vm.parseUint(vm.readFile(string.concat(keysDir, '/', hubKeyFile)));

        c.challengeDuration = uint48(vm.envUint('CHALLENGE_DURATION'));
        c.stateNUser = vm.envUint('STATE_N_USER');
        c.stateN1User = vm.envUint('STATE_N1_USER');
        uint256 reserve = vm.envOr('HUB_RESERVE', uint256(500_000));
        c.total = c.stateN1User + reserve;

        c.secondAsset = vm.envOr('SECOND_ASSET', address(0));
        c.secondAssetAmount = vm.envOr('SECOND_ASSET_AMOUNT', uint256(0));
        c.thirdAsset = vm.envOr('THIRD_ASSET', address(0));
        c.thirdAssetAmount = vm.envOr('THIRD_ASSET_AMOUNT', uint256(0));
    }
}
