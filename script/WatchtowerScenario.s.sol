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
 * Scenario A's watcher response is `respond`: broadcasting `concludeAndTransferAllAssets` with
 * the fully-signed, final state N+1. `_conclude` (ForceMove.sol) only requires the channel not
 * already be finalized and the candidate be unanimously signed and final -- it does not care
 * whether a stale challenge is outstanding or whether the challenge window has elapsed. That
 * makes it strictly simpler than a `checkpoint` (which only clears the challenge and still needs
 * a later `transferAllAssets` once some state finalizes) while being just as valid a ForceMove
 * response, and it is what actually defeats a stale force-close the fastest: a single
 * transaction, immediately, finalizes the channel on the newer state and pays it out.
 *
 * Scenario B skips `respond` entirely; after the window elapses, `settleStale` pays out the
 * stale challenged state N, mirroring script/FixturenetScenario.s.sol's `settle()`.
 *
 * `payoutSince` reads the Shield logs emitted after a recorded start block for a note paid to
 * USER_PAYOUT_NPK and prints its value on a `PAYOUT_LAMPORTS <value>` line for the orchestrating
 * script (stack/scripts/armada-watchtower-e2e.py) to parse.
 *
 * Environment: CHALLENGE_DURATION (must equal the value env/gates/watchtower/prepare.ts bound
 * into both channels' adaptParams), MANIFEST_PATH (default /env/manifest.json), DEPOSITS_PATH
 * (default /env/watchtower-e2e/deposits.json), KEYS_DIR (default /env -- deployer.key and both
 * test accounts' privateKeyFile live under here), STATE_N_USER, STATE_N1_USER, HUB_RESERVE
 * (uint256 base units).
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
    /// state N+1 via `concludeAndTransferAllAssets` -- finalizes and pays out immediately,
    /// regardless of the outstanding challenge or how much of the window remains.
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
        vm.broadcast(c.deployerKey);
        c.adjudicator.concludeAndTransferAllAssets(fp, signedN1);
    }

    /// @dev Scenario B: no response arrived; after the challenge window has elapsed, pay out the
    /// stale challenged state N (mirrors script/FixturenetScenario.s.sol's `settle()`).
    function settleStale(uint256 index) external {
        Ctx memory c = _ctx();
        Deposit memory d = _deposit(index);
        INitroTypes.FixedPart memory fp = _fixedPart(c, d.channelNonce);
        INitroTypes.VariablePart memory stateN = _stateN(c);
        vm.broadcast(c.deployerKey);
        c.adjudicator.transferAllAssets(
            NitroUtils.getChannelId(fp),
            stateN.outcome,
            NitroUtils.hashState(fp, stateN)
        );
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
        return ChannelStates.state(
            address(c.usdc),
            USER_PAYOUT_NPK,
            c.hub,
            TURN_N,
            false,
            c.stateNUser,
            c.total - c.stateNUser
        );
    }

    function _stateN1(Ctx memory c) internal view returns (INitroTypes.VariablePart memory) {
        return ChannelStates.state(
            address(c.usdc),
            USER_PAYOUT_NPK,
            c.hub,
            TURN_N1,
            true,
            c.stateN1User,
            c.total - c.stateN1User
        );
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
    }
}
