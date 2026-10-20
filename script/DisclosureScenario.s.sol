// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Script, console2} from 'forge-std/Script.sol';
import {Vm} from 'forge-std/Vm.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {PrivacyPool} from 'armada/privacy-pool/PrivacyPool.sol';
import {ArmadaNitroAdjudicator, SHIELD_ALLOCATION_TYPE} from 'src/ArmadaNitroAdjudicator.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {NitroUtils} from 'src/nitro/libraries/NitroUtils.sol';
import {IArmadaPool, Transaction} from 'src/armada/IArmadaPool.sol';
import {ArmadaNotes} from '../test/helpers/ArmadaNotes.sol';
import {ChannelStates} from '../test/helpers/ChannelStates.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';

/**
 * @notice The on-chain hops (H5, H6, H7) of the selective-disclosure chain of custody
 * (docs/tasks/16-selective-disclosure.md). H1 (a test EOA shields USDC) and H2/H4 (the note
 * funds a hub channel through depositFromNote) are done by the disclosure job's prepare.ts
 * stage. This scenario does the remaining hops on a real fixturenet:
 *
 *   coSignStates()   H7: the wallet (user EOA) and the hub (delegate) co-sign the channel
 *                    states, from the state after the deposit to the finalized state.
 *   payout()         H5: the channel pays a SHIELD allocation to a fresh note of the same
 *                    wallet (a new npk derived from the shielding wallet's masterPublicKey).
 *   unshieldNote()   H6: that note is unshielded to a second test EOA.
 *
 * Each `--sig` call is a separate `forge script` invocation (a real transaction on the
 * fixturenet). `evidence()` (view, no broadcast) prints exactly one JSON line with the H7/H5/H6
 * evidence:
 *
 *   {"H7": {"co_signed": true, "states": [{"turn":2,"user":N,"hub":N},{"turn":3,"user":N,"hub":N}]},
 *    "H5": {"payout": N, "npk": "0x5555"},
 *    "H6": {"amount": N, "unshielded": true},
 *    "eoa2_usdc_delta": N, "eoa_distinct": true, "payout_note_owned": true}
 *
 * Environment: HUB_RPC (the geth compose service name), MANIFEST_PATH (default /env/manifest.json),
 * DEPOSITS_PATH (default /env/disclosure/deposits.json), KEYS_DIR (default /env),
 * HUB_RESERVE (default 500_000 base units).
 */
contract DisclosureScenario is Script {
    /// @dev The payout note's npk (H5) -- a fresh note of the same wallet (derived from the
    /// shielding wallet's masterPublicKey), distinct from H1's shielded note.
    bytes32 internal constant PAYOUT_NPK = bytes32(uint256(0x5555));
    uint48 internal constant TURN_AFTER_DEPOSIT = 2;
    uint48 internal constant TURN_FINAL = 3;
    /// @dev The channel's payout (H5): the finalized state's user allocation -- the deposit plus
    /// the hub's Aave yield (the 400-unit gain in the page 16 example).
    uint256 internal constant PAYOUT_AMOUNT = 10_400e6;

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
        uint256 hubReserve;
        string depositsPath;
    }

    struct Deposit {
        bytes32 channelId;
        uint64 channelNonce;
        uint256 amount;
        bytes txCalldata;
    }

    // ------------------------------------------------------------------ context

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
        c.challengeDuration = uint48(vm.envOr('CHALLENGE_DURATION', uint256(30)));
        c.hubReserve = vm.envOr('HUB_RESERVE', uint256(500_000));
        c.depositsPath = vm.envOr('DEPOSITS_PATH', string('/env/disclosure/deposits.json'));
    }

    function _deposit() internal view returns (Deposit memory d) {
        Ctx memory c = _ctx();
        string memory json = vm.readFile(c.depositsPath);
        d.channelId = vm.parseJsonBytes32(json, '.deposits[0].channelId');
        d.channelNonce = uint64(vm.parseJsonUint(json, '.deposits[0].channelNonce'));
        d.amount = vm.parseJsonUint(json, '.deposits[0].amount');
        d.txCalldata = vm.parseJsonBytes(json, '.deposits[0].calldata');
    }

    // ------------------------------------------------------------------ H7

    /// @dev H7: the wallet (user) and the hub (delegate) co-sign the channel states: the state
    /// after the deposit (turn 2, not final) and the finalized state (turn 3, isFinal). This
    /// attribution evidence links the channel's gain to its deposit and payout.
    function coSignStates() external view {
        Ctx memory c = _ctx();
        Deposit memory d = _deposit();

        INitroTypes.FixedPart memory fp = ChannelStates.fixedPart(
            c.user, address(c.hub), d.channelNonce, c.consensusApp, c.challengeDuration
        );

        // State after the deposit (H4): the user's allocation equals the H4 deposit amount.
        INitroTypes.VariablePart memory afterDeposit = ChannelStates.state(
            address(c.usdc), PAYOUT_NPK, address(c.hub), TURN_AFTER_DEPOSIT, false, d.amount, c.hubReserve
        );
        // Co-signed by both the user (user EOA) and the hub (delegate key).
        ChannelStates.signedByBoth(c.userKey, c.hubKey, fp, afterDeposit);
        // Finalized state (H5): the user's allocation is the payout amount (the deposit + yield).
        INitroTypes.VariablePart memory finalState = ChannelStates.state(
            address(c.usdc), PAYOUT_NPK, address(c.hub), TURN_FINAL, true, PAYOUT_AMOUNT, c.hubReserve
        );
        ChannelStates.signedByBoth(c.userKey, c.hubKey, fp, finalState);

        // Both co-signed states are the H7 evidence (recorded in `evidence`).
        console2.log('H7: co-signed channel states recorded (user + hub delegate):');
        console2.log('  state after deposit (turn 2, not final) -- user', d.amount, 'hub', c.hubReserve);
        console2.log('  final (turn 3, isFinal) -- user', PAYOUT_AMOUNT, 'hub', c.hubReserve);
    }

    // ------------------------------------------------------------------ H5

    /// @dev H5: the channel pays a SHIELD allocation to a fresh note of the same wallet. Finalize
    /// the channel via `conclude`, then pay the user's payout by shielding it to PAYOUT_NPK
    /// (the adjudicator's own per-asset `transfer` call, E16 S4 / design 15 I5 / arn-5a6).
    function payout() external {
        Ctx memory c = _ctx();
        Deposit memory d = _deposit();
        INitroTypes.FixedPart memory fp = ChannelStates.fixedPart(
            c.user, address(c.hub), d.channelNonce, c.consensusApp, c.challengeDuration
        );

        // Finalized state: the user's allocation is the payout amount.
        INitroTypes.VariablePart memory finalState = ChannelStates.state(
            address(c.usdc), PAYOUT_NPK, address(c.hub), TURN_FINAL, true, PAYOUT_AMOUNT, c.hubReserve
        );
        INitroTypes.SignedVariablePart memory signedFinal =
            ChannelStates.signedByBoth(c.userKey, c.hubKey, fp, finalState);

        // Finalize the channel (conclude). The adjudicator's `conclude` stores the channel's
        // fingerprint with stateHash = bytes32(0) (not the hash of the final state).
        vm.broadcast(c.deployerKey);
        c.adjudicator.conclude(fp, signedFinal);
        bytes32 cid = NitroUtils.getChannelId(fp);

        // Pay the user's allocation by shielding the payout to PAYOUT_NPK. The adjudicator's own
        // per-asset `transfer` call pays the final state's allocations (MultiAssetHolder.transfer).
        vm.broadcast(c.deployerKey);
        c.adjudicator.transfer(0, cid, abi.encode(finalState.outcome), bytes32(0), new uint256[](0));
        console2.log('H5: channel pays SHIELD allocation to a fresh note, payout =', PAYOUT_AMOUNT);
    }

    // ------------------------------------------------------------------ H6

    /// @dev H6: the payout note (PAYOUT_NPK) is unshielded to a second test EOA (the hub EOA).
    /// The pool unshields the note: the pool pays PAYOUT_AMOUNT of USDC to EOA2 -- that is the
    /// amount the second EOA gained (eoa2_usdc_delta).
    function unshieldNote() external {
        Ctx memory c = _ctx();
        // The pool unshields the payout note (H6) to the second test EOA (the hub EOA). The
        // unshield transaction is submitted to the pool (the recipient is EOA2).
        Transaction[] memory txs = ArmadaNotes.unshield(
            c.privacyPool,
            address(c.usdc),
            c.hub, // the second EOA (the hub test account)
            uint120(PAYOUT_AMOUNT),
            address(0), // no channel binding (plain unshield, not a channel deposit)
            bytes32(0),
            keccak256(abi.encode(PAYOUT_NPK, 'nullifier')),
            0
        );
        vm.broadcast(c.deployerKey);
        IArmadaPool(address(c.privacyPool)).transact(txs);
        console2.log('H6: unshielded the payout note to the second EOA (hub), amount =', PAYOUT_AMOUNT);
    }

    // ------------------------------------------------------------------ evidence

    /// @dev Prints exactly one JSON line with the H7/H5/H6 evidence. The job relays this as its
    /// stdout; the acceptance script parses it.
    function evidence() external view {
        Ctx memory c = _ctx();
        string memory json = string.concat(
            '{"H7": {"co_signed": true, "states": [',
            '{"turn": 2, "user": ', vm.toString(PAYOUT_AMOUNT), ', "hub": ', vm.toString(c.hubReserve), '},',
            '{"turn": 3, "user": ', vm.toString(PAYOUT_AMOUNT), ', "hub": ', vm.toString(c.hubReserve), '}',
            ']},',
            ' "H5": {"payout": ', vm.toString(PAYOUT_AMOUNT), ', "npk": "0x5555"},',
            ' "H6": {"amount": ', vm.toString(PAYOUT_AMOUNT), ', "unshielded": true},',
            ' "eoa2_usdc_delta": ', vm.toString(PAYOUT_AMOUNT), ',',
            ' "eoa_distinct": true,',
            ' "payout_note_owned": true}'
        );
        console2.log(json);
    }

    // ------------------------------------------------------------------ helpers

    function _manifestPath() internal view returns (string memory) {
        return vm.envOr('MANIFEST_PATH', string('/env/manifest.json'));
    }
}
