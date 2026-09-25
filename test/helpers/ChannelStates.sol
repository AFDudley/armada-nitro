// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Vm} from 'forge-std/Vm.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {NitroUtils} from 'src/nitro/libraries/NitroUtils.sol';
import {SHIELD_ALLOCATION_TYPE} from 'src/ArmadaNitroAdjudicator.sol';
import {ArmadaNotes} from './ArmadaNotes.sol';

/**
 * @dev States for a user<->hub USDC channel, shared by the tests and the local scripts. The user
 * is paid by shielding a note to `userNpk`; the hub is paid to its custodian address.
 */
library ChannelStates {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));

    function fixedPart(
        address user,
        address custodian,
        uint64 channelNonce,
        address app,
        uint48 challengeDuration
    ) internal pure returns (INitroTypes.FixedPart memory) {
        address[] memory participants = new address[](2);
        participants[0] = user;
        participants[1] = custodian;
        return
            INitroTypes.FixedPart({
                participants: participants,
                channelNonce: channelNonce,
                appDefinition: app,
                challengeDuration: challengeDuration
            });
    }

    function state(
        address usdc,
        bytes32 userNpk,
        address custodian,
        uint48 turnNum,
        bool isFinal,
        uint256 userAmount,
        uint256 hubAmount
    ) internal pure returns (INitroTypes.VariablePart memory) {
        Outcome.Allocation[] memory allocations = new Outcome.Allocation[](2);
        allocations[0] = Outcome.Allocation({
            destination: userNpk,
            amount: userAmount,
            allocationType: SHIELD_ALLOCATION_TYPE,
            metadata: abi.encode(ArmadaNotes.ciphertext(userNpk))
        });
        allocations[1] = Outcome.Allocation({
            destination: bytes32(uint256(uint160(custodian))),
            amount: hubAmount,
            allocationType: uint8(Outcome.AllocationType.simple),
            metadata: ''
        });
        Outcome.SingleAssetExit[] memory outcome = new Outcome.SingleAssetExit[](1);
        outcome[0] = Outcome.SingleAssetExit({
            asset: usdc,
            assetMetadata: Outcome.AssetMetadata({assetType: Outcome.AssetType.Default, metadata: ''}),
            allocations: allocations
        });
        return
            INitroTypes.VariablePart({
                outcome: outcome,
                appData: '',
                turnNum: turnNum,
                isFinal: isFinal
            });
    }

    function sign(
        uint256 key,
        INitroTypes.FixedPart memory fp,
        INitroTypes.VariablePart memory vp
    ) internal pure returns (INitroTypes.Signature memory) {
        return signDigest(key, NitroUtils.hashState(fp, vp));
    }

    /// @dev The user signs as an EOA; the hub signs with its delegate key, checked via the custodian.
    function signedByBoth(
        uint256 userKey,
        uint256 delegateKey,
        INitroTypes.FixedPart memory fp,
        INitroTypes.VariablePart memory vp
    ) internal pure returns (INitroTypes.SignedVariablePart memory) {
        INitroTypes.Signature[] memory sigs = new INitroTypes.Signature[](2);
        sigs[0] = sign(userKey, fp, vp);
        sigs[1] = sign(delegateKey, fp, vp);
        return INitroTypes.SignedVariablePart({variablePart: vp, sigs: sigs});
    }

    function challengerSig(
        uint256 key,
        INitroTypes.FixedPart memory fp,
        INitroTypes.VariablePart memory vp
    ) internal pure returns (INitroTypes.Signature memory) {
        return signDigest(key, keccak256(abi.encode(NitroUtils.hashState(fp, vp), 'forceMove')));
    }

    function signDigest(
        uint256 key,
        bytes32 digest
    ) internal pure returns (INitroTypes.Signature memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, NitroUtils.prefixedHash(digest));
        return INitroTypes.Signature({v: v, r: r, s: s});
    }
}
