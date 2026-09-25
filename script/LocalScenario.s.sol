// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Script, console2} from 'forge-std/Script.sol';
import {Vm} from 'forge-std/Vm.sol';
import {PrivacyPool} from 'armada/privacy-pool/PrivacyPool.sol';
import {MockUSDCV2} from 'armada/cctp/MockUSDCV2.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {NitroUtils} from 'src/nitro/libraries/NitroUtils.sol';
import {IArmadaPool, CommitmentPreimage, ShieldCiphertext, Transaction} from 'src/armada/IArmadaPool.sol';
import {ArmadaNotes} from '../test/helpers/ArmadaNotes.sol';
import {ChannelStates} from '../test/helpers/ChannelStates.sol';
import {IHubCustodian, IFrostTestSigner} from '../test/helpers/IHubCustodian.sol';

/**
 * @notice End-to-end run on a local anvil node against deployments/31337*.json. Each phase is a
 * separate `forge script --sig` call so the force-close waits out a real challenge window:
 *
 *   setUpHub         authorize the hub's delegate (FROST-signed) and stock the custodian
 *   cooperativeClose fund a channel from a note + custodian, conclude, shield the user's payout
 *   openAndChallenge fund a second channel; the user challenges with the latest co-signed state
 *   settle           after the window: pay out the challenged outcome
 *   verify           read chain state and Shield logs; revert on any mismatch
 *
 * Environment: DEPLOYER_KEY, USER_KEY, DELEGATE_KEY, HUB_GROUP_SCALAR, CHALLENGE_DURATION.
 */
contract LocalScenario is Script {
    bytes32 internal constant USER_DEPOSIT_NPK = bytes32(uint256(0x1111));
    bytes32 internal constant USER_PAYOUT_NPK = bytes32(uint256(0x2222));
    uint120 internal constant USER_FUNDS = 100e6;
    uint120 internal constant HUB_FUNDS = 100e6;
    uint256 internal constant HUB_STOCK = 1_000e6;

    uint256 internal constant COOPERATIVE_USER = 130e6;
    uint256 internal constant COOPERATIVE_HUB = 70e6;
    uint256 internal constant FORCED_USER = 150e6;
    uint256 internal constant FORCED_HUB = 50e6;

    string internal constant COOPERATIVE_NONCE = 'deployments/31337-scenario-cooperative-nonce';
    string internal constant CHALLENGE_NONCE = 'deployments/31337-scenario-challenge-nonce';
    string internal constant START_BLOCK = 'deployments/31337-scenario-start-block';
    string internal constant HUB_START_BALANCE = 'deployments/31337-scenario-hub-balance';

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

    function setUpHub() external {
        Ctx memory c = _ctx();
        _hubExecute(
            c,
            address(c.custodian),
            abi.encodeCall(IHubCustodian.authorizeDelegate, (vm.addr(c.delegateKey)))
        );
        vm.broadcast(c.deployerKey);
        c.usdc.mint(address(c.custodian), HUB_STOCK);
        vm.writeFile(START_BLOCK, vm.toString(block.number));
        vm.writeFile(HUB_START_BALANCE, vm.toString(c.usdc.balanceOf(address(c.custodian))));
    }

    function cooperativeClose() external {
        Ctx memory c = _ctx();
        uint64 nonce = uint64(block.timestamp);
        INitroTypes.FixedPart memory fp = _fixedPart(c, nonce);
        _fund(c, NitroUtils.getChannelId(fp));

        INitroTypes.VariablePart memory finalState = _state(c, 7, true, COOPERATIVE_USER, COOPERATIVE_HUB);
        INitroTypes.SignedVariablePart memory signedFinal = ChannelStates.signedByBoth(
            c.userKey,
            c.delegateKey,
            fp,
            finalState
        );
        vm.broadcast(c.deployerKey);
        c.adjudicator.concludeAndTransferAllAssets(fp, signedFinal);
        vm.writeFile(COOPERATIVE_NONCE, vm.toString(nonce));
    }

    function openAndChallenge() external {
        Ctx memory c = _ctx();
        uint64 nonce = uint64(block.timestamp) + 1;
        INitroTypes.FixedPart memory fp = _fixedPart(c, nonce);
        _fund(c, NitroUtils.getChannelId(fp));

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
        vm.writeFile(CHALLENGE_NONCE, vm.toString(nonce));
        console2.log('challenge window (s)', c.challengeDuration);
    }

    function settle() external {
        Ctx memory c = _ctx();
        INitroTypes.FixedPart memory fp = _fixedPart(c, _readNonce(CHALLENGE_NONCE));
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
        bytes32 cooperative = NitroUtils.getChannelId(_fixedPart(c, _readNonce(COOPERATIVE_NONCE)));
        bytes32 forced = NitroUtils.getChannelId(_fixedPart(c, _readNonce(CHALLENGE_NONCE)));
        require(c.adjudicator.holdings(address(c.usdc), cooperative) == 0, 'cooperative channel not emptied');
        require(c.adjudicator.holdings(address(c.usdc), forced) == 0, 'forced channel not emptied');
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
                if (notes[j].value == COOPERATIVE_USER) cooperativePaid = true;
                if (notes[j].value == FORCED_USER) forcedPaid = true;
            }
        }
        require(cooperativePaid, 'no shielded note for the cooperative close');
        require(forcedPaid, 'no shielded note for the force-close');
        console2.log('verified: both channels paid the user by shielding a note');
    }

    // ---------------------------------------------------------------- helpers

    /// @dev User funds from a shielded note (unshield bound to the channel); hub from its custodian.
    function _fund(Ctx memory c, bytes32 channelId) internal {
        address user = vm.addr(c.userKey);
        vm.broadcast(c.deployerKey);
        c.usdc.mint(user, USER_FUNDS);
        vm.startBroadcast(c.userKey);
        c.usdc.approve(address(c.privacyPool), USER_FUNDS);
        IArmadaPool(address(c.privacyPool)).shield(
            ArmadaNotes.shieldRequests(address(c.usdc), USER_DEPOSIT_NPK, USER_FUNDS),
            address(0)
        );
        vm.stopBroadcast();

        Transaction[] memory txs = ArmadaNotes.unshield(
            c.privacyPool,
            address(c.usdc),
            address(c.adjudicator),
            USER_FUNDS,
            address(c.adjudicator),
            c.adjudicator.depositBinding(channelId, 0),
            keccak256(abi.encode(channelId, 'nullifier'))
        );
        vm.broadcast(c.deployerKey);
        c.adjudicator.depositFromNote(channelId, 0, txs);

        _hubExecute(
            c,
            address(c.usdc),
            abi.encodeWithSignature('approve(address,uint256)', address(c.adjudicator), HUB_FUNDS)
        );
        _hubExecute(
            c,
            address(c.adjudicator),
            abi.encodeCall(c.adjudicator.deposit, (address(c.usdc), channelId, USER_FUNDS, HUB_FUNDS))
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

    function _fixedPart(Ctx memory c, uint64 nonce) internal pure returns (INitroTypes.FixedPart memory) {
        return
            ChannelStates.fixedPart(
                vm.addr(c.userKey),
                address(c.custodian),
                nonce,
                c.consensusApp,
                c.challengeDuration
            );
    }

    function _state(
        Ctx memory c,
        uint48 turnNum,
        bool isFinal,
        uint256 userAmount,
        uint256 hubAmount
    ) internal pure returns (INitroTypes.VariablePart memory) {
        return
            ChannelStates.state(
                address(c.usdc),
                USER_PAYOUT_NPK,
                address(c.custodian),
                turnNum,
                isFinal,
                userAmount,
                hubAmount
            );
    }

    function _readNonce(string memory path) internal view returns (uint64) {
        return uint64(vm.parseUint(vm.readFile(path)));
    }

    function _ctx() internal view returns (Ctx memory c) {
        string memory armada = vm.readFile('deployments/31337-armada.json');
        string memory ours = vm.readFile('deployments/31337.json');
        c.privacyPool = PrivacyPool(payable(vm.parseJsonAddress(armada, '.pool')));
        c.usdc = MockUSDCV2(vm.parseJsonAddress(armada, '.usdc'));
        c.adjudicator = ArmadaNitroAdjudicator(vm.parseJsonAddress(ours, '.adjudicator'));
        c.consensusApp = vm.parseJsonAddress(ours, '.consensusApp');
        c.custodian = IHubCustodian(vm.parseJsonAddress(ours, '.hubCustodian'));
        c.deployerKey = vm.envUint('DEPLOYER_KEY');
        c.userKey = vm.envUint('USER_KEY');
        c.delegateKey = vm.envUint('DELEGATE_KEY');
        c.groupScalar = vm.envUint('HUB_GROUP_SCALAR');
        c.challengeDuration = uint48(vm.envUint('CHALLENGE_DURATION'));
    }
}
