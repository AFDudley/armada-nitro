// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {ExitFormat as Outcome} from '@statechannels/exit-format/contracts/ExitFormat.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {INitroTypes} from 'src/nitro/interfaces/INitroTypes.sol';
import {NitroUtils} from 'src/nitro/libraries/NitroUtils.sol';
import {ArmadaFixture} from './helpers/ArmadaFixture.sol';
import {ChannelStates} from './helpers/ChannelStates.sol';
import {RevertingTransferToken} from './helpers/RevertingTransferToken.sol';

/// @dev A channel asset whose `transfer` returns `false` and moves nothing, as some ERC20s do
/// instead of reverting. `transferFrom` is standard, so a deposit funds the channel normally.
contract FalseTransferToken is ERC20 {
    constructor(uint256 initialSupply) ERC20('False Token', 'FALSE') {
        _mint(msg.sender, initialSupply);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev E16 S4 (design 15, I5): in a finalized two-asset channel whose second asset's token
/// reverts on `transfer`, `transferAllAssets` reverts as a whole and pays nothing, while
/// `transfer(assetIndex)` pays the first asset to its recipient. The E16 convention "SafeERC20
/// for every token call" also holds for payouts: a token `transfer` that returns `false` reverts
/// the payout. See docs/tasks/E16-adjudicator-hardening.md.
contract PerAssetExitTest is ArmadaFixture, INitroTypes {
    ArmadaNitroAdjudicator internal adjudicator;
    RevertingTransferToken internal blocked;
    FalseTransferToken internal falseToken;

    uint256 internal constant PARTICIPANT_KEY = 0xA11CE;
    address internal constant USDC_RECIPIENT = address(0xBEEF);
    address internal constant BLOCKED_RECIPIENT = address(0xCAFE);
    uint256 internal constant USDC_AMOUNT = 70e6;
    uint256 internal constant BLOCKED_AMOUNT = 30e18;

    function setUp() public {
        _deployArmada();
        blocked = new RevertingTransferToken(BLOCKED_AMOUNT);
        falseToken = new FalseTransferToken(BLOCKED_AMOUNT);
        address[] memory assets = new address[](3);
        assets[0] = address(usdc);
        assets[1] = address(blocked);
        assets[2] = address(falseToken);
        adjudicator = new ArmadaNitroAdjudicator(pool, assets);
    }

    function test_transferAssetIndex_paysOtherAsset_whenOneAssetsTransferReverts() public {
        (bytes32 channelId, Outcome.SingleAssetExit[] memory outcome, bytes32 stateHash) = _fundAndConclude(
            address(blocked),
            16
        );

        // transferAllAssets reverts as a whole: neither asset moves.
        vm.expectRevert('RevertingTransferToken: transfer blocked');
        adjudicator.transferAllAssets(channelId, outcome, stateHash);
        assertEq(usdc.balanceOf(USDC_RECIPIENT), 0, 'all-assets payout paid USDC');
        assertEq(adjudicator.holdings(address(usdc), channelId), USDC_AMOUNT);
        assertEq(adjudicator.holdings(address(blocked), channelId), BLOCKED_AMOUNT);

        // transfer(0) pays the USDC allocation alone.
        adjudicator.transfer(0, channelId, abi.encode(outcome), stateHash, new uint256[](0));
        assertEq(usdc.balanceOf(USDC_RECIPIENT), USDC_AMOUNT, 'per-asset payout did not pay USDC');
        assertEq(adjudicator.holdings(address(usdc), channelId), 0);
        // The blocked asset stays held for the channel, not lost.
        assertEq(adjudicator.holdings(address(blocked), channelId), BLOCKED_AMOUNT);
        assertEq(blocked.balanceOf(address(adjudicator)), BLOCKED_AMOUNT);
        assertEq(blocked.balanceOf(BLOCKED_RECIPIENT), 0);
    }

    function test_transferAssetIndex_reverts_whenTokenTransferReturnsFalse() public {
        (bytes32 channelId, Outcome.SingleAssetExit[] memory outcome, bytes32 stateHash) = _fundAndConclude(
            address(falseToken),
            17
        );

        // The payout of the false-returning asset reverts: the channel keeps its credit.
        vm.expectRevert('SafeERC20: ERC20 operation did not succeed');
        adjudicator.transfer(1, channelId, abi.encode(outcome), stateHash, new uint256[](0));
        assertEq(adjudicator.holdings(address(falseToken), channelId), BLOCKED_AMOUNT);
        assertEq(falseToken.balanceOf(address(adjudicator)), BLOCKED_AMOUNT);
        assertEq(falseToken.balanceOf(BLOCKED_RECIPIENT), 0);
    }

    /// @dev Deposit USDC and `second` into a one-participant channel and conclude it with a final
    /// state whose outcome pays each asset to an external address.
    function _fundAndConclude(
        address second,
        uint64 channelNonce
    )
        internal
        returns (bytes32 channelId, Outcome.SingleAssetExit[] memory outcome, bytes32 stateHash)
    {
        address[] memory participants = new address[](1);
        participants[0] = vm.addr(PARTICIPANT_KEY);
        FixedPart memory fixedPart = FixedPart({
            participants: participants,
            channelNonce: channelNonce,
            appDefinition: address(0),
            challengeDuration: 1 days
        });
        channelId = NitroUtils.getChannelId(fixedPart);

        usdc.mint(address(this), USDC_AMOUNT);
        usdc.approve(address(adjudicator), USDC_AMOUNT);
        adjudicator.deposit(address(usdc), channelId, 0, USDC_AMOUNT);
        ERC20(second).approve(address(adjudicator), BLOCKED_AMOUNT);
        adjudicator.deposit(second, channelId, 0, BLOCKED_AMOUNT);

        outcome = new Outcome.SingleAssetExit[](2);
        outcome[0] = _exitTo(address(usdc), USDC_RECIPIENT, USDC_AMOUNT);
        outcome[1] = _exitTo(second, BLOCKED_RECIPIENT, BLOCKED_AMOUNT);
        VariablePart memory variablePart = VariablePart({
            outcome: outcome,
            appData: '',
            turnNum: 1,
            isFinal: true
        });
        Signature[] memory sigs = new Signature[](1);
        sigs[0] = ChannelStates.sign(PARTICIPANT_KEY, fixedPart, variablePart);
        adjudicator.conclude(fixedPart, SignedVariablePart({variablePart: variablePart, sigs: sigs}));
        // `conclude` records the outcome fingerprint with a zero state hash.
        stateHash = bytes32(0);
    }

    function _exitTo(
        address asset,
        address recipient,
        uint256 amount
    ) internal pure returns (Outcome.SingleAssetExit memory) {
        Outcome.Allocation[] memory allocations = new Outcome.Allocation[](1);
        allocations[0] = Outcome.Allocation(
            bytes32(uint256(uint160(recipient))),
            amount,
            uint8(Outcome.AllocationType.simple),
            ''
        );
        return Outcome.SingleAssetExit(asset, Outcome.AssetMetadata(Outcome.AssetType.Default, ''), allocations);
    }
}
