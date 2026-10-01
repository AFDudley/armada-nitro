// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Script, console2} from 'forge-std/Script.sol';
import {Vm} from 'forge-std/Vm.sol';
import {PrivacyPool} from 'armada/privacy-pool/PrivacyPool.sol';
import {MockUSDCV2} from 'armada/cctp/MockUSDCV2.s.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {NitroUtils} from 'src/nitro/libraries/NitroUtils.sol';
import {IArmadaPool, Transaction} from 'src/armada/IArmadaPool.sol';
import {ArmadaNotes} from '../../test/helpers/ArmadaNotes.sol';
import {ChannelStates} from '../../test/helpers/ChannelStates.sol';
import {IHubCustodian} from '../../test/helpers/IHubCustodian.sol';

/// @notice Watchtower e2e scenario. A new channel is funded; the user holds a newer fully signed
/// state (turn N+1). A scripted counterparty challenge (stale turn N or current turn N+1) is
/// answered on-chain by the watcher (env/gates/watchtower/watch.ts) when the challenge's turn is
/// lower than the held state's turn.
///
///   setupChannel    fund a new channel (user note + hub custodian), sign states N and N+1, write
///                    the held state (turn N+1) to the watcher's input file (env/gates/watchtower/
///                    held-state.json), and persist the channel nonce for the challenge phases.
///   challengeStale  the counterparty challenges with the stale state (turn N)
///   challengeCurrent the counterparty challenges with the latest state (turn N+1)
///
/// Environment: MANIFEST_PATH (the fixturenet manifest), DEPLOYER_KEY, USER_KEY, DELEGATE_KEY,
/// HUB_GROUP_SCALAR, CHALLENGE_DURATION.
///
/// The watcher (watch.ts) reads held-state.json and answers the challenge.
contract WatchtowerScenario is Script {
    bytes32 internal constant USER_DEPOSIT_NPK = bytes32(uint256(0x3333));
    bytes32 internal constant USER_PAYOUT_NPK = bytes32(uint256(0x4444));

    struct Ctx {
        PrivacyPool privacyPool;
        MockUSDCV2 usdc;
        ArmadaNitroAdjudicator adjudicator;
        address consensusApp;
        IHubCustodian custodian;
        uint256 deployerKey;
        uint256 userKey;
        uint256 delegateKey;
        uint256 groupScalar;
        uint48 challengeDuration;
    }

    string internal constant HELD_STATE_PATH = 'env/gates/watchtower/held-state.json';
    string internal constant CHANNEL_NONCE_PATH = 'env/gates/watchtower/channel-nonce';

    function setupChannel() external {
        Ctx memory c = _ctx();
        uint64 nonce = uint64(block.timestamp) + 1;
        INitroTypes.FixedPart memory fp = ChannelStates.fixedPart(
            vm.addr(c.userKey), address(c.custodian), nonce, c.consensusApp, c.challengeDuration
        );
        bytes32 channelId = NitroUtils.getChannelId(fp);
        _fund(c, channelId);

        INitroTypes.VariablePart memory stale = _state(c, 12, false, 100e6, 100e6);
        INitroTypes.VariablePart memory held = _state(c, 13, false, 150e6, 50e6);
        INitroTypes.SignedVariablePart memory signedHeld = ChannelStates.signedByBoth(
            c.userKey, c.delegateKey, fp, held
        );
        vm.writeFile(CHANNEL_NONCE_PATH, vm.toString(nonce));
        _writeHeldState(fp, signedHeld, channelId);
        console2.log('channelId', channelId);
        console2.log('challenge window (s)', c.challengeDuration);
    }

    function challengeStale() external {
        Ctx memory c = _ctx();
        uint64 nonce = uint64(vm.parseUint(vm.readFile(CHANNEL_NONCE_PATH)));
        INitroTypes.FixedPart memory fp = ChannelStates.fixedPart(
            vm.addr(c.userKey), address(c.custodian), nonce, c.consensusApp, c.challengeDuration
        );
        INitroTypes.VariablePart memory stale = _state(c, 12, false, 100e6, 100e6);
        INitroTypes.SignedVariablePart memory signedStale = ChannelStates.signedByBoth(
            c.userKey, c.delegateKey, fp, stale
        );
        INitroTypes.Signature memory challengerSig = ChannelStates.challengerSig(c.userKey, fp, stale);
        vm.startBroadcast(c.userKey);
        c.adjudicator.challenge(fp, new INitroTypes.SignedVariablePart[](0), signedStale, challengerSig);
        vm.stopBroadcast();
        console2.log('challenged with stale state (turn 12)');
    }

    function challengeCurrent() external {
        Ctx memory c = _ctx();
        uint64 nonce = uint64(vm.parseUint(vm.readFile(CHANNEL_NONCE_PATH)));
        INitroTypes.FixedPart memory fp = ChannelStates.fixedPart(
            vm.addr(c.userKey), address(c.custodian), nonce, c.consensusApp, c.challengeDuration
        );
        INitroTypes.VariablePart memory held = _state(c, 13, false, 150e6, 50e6);
        INitroTypes.SignedVariablePart memory signedHeld = ChannelStates.signedByBoth(
            c.userKey, c.delegateKey, fp, held
        );
        INitroTypes.Signature memory challengerSig = ChannelStates.challengerSig(c.userKey, fp, held);
        vm.startBroadcast(c.userKey);
        c.adjudicator.challenge(fp, new INitroTypes.SignedVariablePart[](0), signedHeld, challengerSig);
        vm.stopBroadcast();
    }

    // ---------------------------------------------------------------- helpers

    function _fund(Ctx memory c, bytes32 channelId) internal {
        address user = vm.addr(c.userKey);
        vm.broadcast(c.deployerKey);
        c.usdc.mint(address(c.usdc), 100e6);
        vm.startBroadcast(c.userKey);
        c.usdc.approve(address(c.privacyPool), 100e6);
        IArmadaPool(address(c.privacyPool)).shield(
            ArmadaNotes.shieldRequests(address(c.usdc), USER_DEPOSIT_NPK, 100e6), address(0)
        );
        vm.stopBroadcast();

        Transaction[] memory txs = ArmadaNotes.unshield(
            c.privacyPool, c.usdc, address(c.adjudicator), 100e6, address(c.adjudicator),
            c.adjudicator.depositBinding(channelId, 0), keccak256(abi.encode(channelId, 'nullifier'))
        );
        vm.broadcast(c.deployerKey);
        c.adjudicator.depositFromNote(channelId, 0, txs);

        _hubExecute(c, address(c.usdc),
            abi.encodeWithSignature('approve(address,uint256)', address(c.adjudicator), 100e6));
        _hubExecute(c, address(c.adjudicator),
            abi.encodeCall(c.adjudicator.deposit, (address(c.usdc), channelId, 100e6, 100e6)));
    }

    function _hubExecute(Ctx memory c, address target, bytes memory data) internal {
        INitroTypes.SignedVariablePart[] memory proofs = new INitroTypes.SignedVariablePart[](0);
        c.custodian.execute(target, data, proofs);
    }

    function _state(
        Ctx memory c, uint48 turnNum, bool isFinal, uint256 userAmount, uint256 hubAmount
    ) internal pure returns (INitroTypes.VariablePart memory) {
        return ChannelStates.state(
            address(c.usdc), USER_PAYOUT_NPK, address(c.custodian),
            turnNum, isFinal, userAmount, hubAmount
        );
    }

    function _ctx() internal view returns (Ctx memory c) {
        string memory manifest = vm.readFile(vm.envString('MANIFEST_PATH'));
        c.privacyPool = PrivacyPool(payable(vm.parseJsonAddress(manifest, 'armada.pool'));
        c.usdc = MockUSDCV2(vm.parseJsonAddress(manifest, 'armada.usdc'));
        c.adjudicator = ArmadaNitroAdjudicator(vm.parseJsonAddress(manifest, 'armada_nitro.adjudicator');
        c.consensusApp = vm.parseJsonAddress(manifest, 'armada_nitro.consensusApp');
        c.custodian = IHubCustodian(vm.parseJsonAddress(manifest, 'armada_nitro.hubCustodian');
        c.deployerKey = vm.envUint('DEPLOYER_KEY');
        c.userKey = vm.envUint('USER_KEY');
        c.delegateKey = vm.envUint('DELEGATE_KEY');
        c.groupScalar = vm.envUint('HUB_GROUP_SCALAR');
        c.challengeDuration = uint48(vm.envUint('CHALLENGE_DURATION');
    }

    /// @dev Writes the held state (turn N+1) as JSON to the watcher's input file.
    function _writeHeldState(
        INitroTypes.FixedPart memory fp,
        INitroTypes.SignedVariablePart memory signed,
        bytes32 channelId
    ) internal {
        vm.writeFile(HELD_STATE_PATH, _json(fp, signed, channelId));
    }

    function _json(
        INitroTypes.FixedPart memory fp,
        INitroTypes.SignedVariablePart memory signed,
        bytes32 channelId
    ) internal pure returns (string) {
        string memory s = '{"channelId":"' + _bytes32ToHex(channelId) + '"';
        s += ',"participants":[';
        for (uint i = 0; i < fp.participants.length; i++) {
            if (i > 0) { s += ', '; }
            s += '"' + vm.toString(fp.participants[i]) + '"';
        }
        s += '],"channelNonce":' + vm.toString(fp.channelNonce);
        s += ',"appDefinition":"' + vm.toString(fp.appDefinition) + '"';
        s += ',"challengeDuration":' + vm.toString(uint16(fp.challengeDuration));
        s += ',"variablePart":{"turnNum":' + vm.toString(signed.variablePart.turnNum);
        s += ',"isFinal":' + (signed.variablePart.isFinal ? 'true' : 'false') + '}';
        s += ',"sigs":[';
        for (uint i = 0; i < signed.sigs.length; i++) {
            if (i > 0) { s += ', '; }
            s += '{"v":' + vm.toString(signed.sigs[i].v);
            s += ',"r":"' + _bytes32ToHex(signed.sigs[i].r) + '"';
            s += ',"s":"' + _bytes32ToHex(signed.sigs[i].s) + '"}';
        }
        s += '] }';
        return s;
    }

    function _bytes32ToHex(bytes32 b) internal pure returns (string) {
        return vm.toString(b);
    }
}
