// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test, Vm} from 'forge-std/Test.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {ArmadaFixture} from './helpers/ArmadaFixture.sol';
import {MockPool} from './helpers/MockPool.sol';
import {ArmadaNotes} from './helpers/ArmadaNotes.sol';
import {
    BoundParams,
    CommitmentCiphertext,
    CommitmentPreimage,
    G1Point,
    G2Point,
    IArmadaPool,
    SnarkProof,
    Transaction,
    UnshieldType
} from 'src/armada/IArmadaPool.sol';

/// @dev Minimal ERC20 that delivers exactly the requested amount.
contract NormalToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[address(this)][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (balanceOf[from] < amount) return false;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract DepositAmountTest is ArmadaFixture {
    ArmadaNitroAdjudicator adjudicator;
    MockPool internal _mockPool;
    NormalToken internal normalToken;

    function setUp() public {
        _deployArmada();
        // arn-3d8: the test tokens must be on the adjudicator's configured asset list.
        normalToken = new NormalToken();
        address[] memory assets = new address[](5);
        assets[0] = address(usdc);
        assets[1] = address(0x0000000000000000000000000000000000000001); // WETH
        assets[2] = address(0x0000000000000000000000000000000000000002); // wstETH
        assets[3] = address(0x0000000000000000000000000000000000000003); // waUSDC
        assets[4] = address(normalToken);
        _mockPool = new MockPool();
        adjudicator = new ArmadaNitroAdjudicator(IArmadaPool(address(_mockPool)), assets);
    }

    /// @dev c2: a normal token that pays the full amount leaves the holdings increase equal to the
    /// adjudicator's measured token balance increase.
    function test_normalDeposit_holdingsDeltaEqualsBalanceDelta() public {
        uint256 amount = 50;
        normalToken.mint(address(this), amount);
        normalToken.approve(address(adjudicator), amount);
        bytes32 channelId = keccak256("channel-arn-0cf");

        uint256 heldBefore = adjudicator.heldValue(address(normalToken), channelId);
        uint256 balBefore = normalToken.balanceOf(address(adjudicator));
        adjudicator.depositFromNote(channelId, heldBefore, _buildUnshieldBound(address(normalToken), amount, channelId, heldBefore));
        uint256 heldDelta = adjudicator.heldValue(address(normalToken), channelId) - heldBefore;
        uint256 balDelta = normalToken.balanceOf(address(adjudicator)) - balBefore;

        assertEq(heldDelta, balDelta, 'holdings delta != balance delta');
    }

    /// @dev N1a: builds a local unshield transaction of a fresh note of `tokenAddr` worth `value`
    /// to the adjudicator, mints+shields the backing tokens into the mock pool so `transact`'s
    /// balance delta matches, and registers the note's preimage so heldValue follows it live.
    function _buildUnshieldBound(address tokenAddr, uint256 value, bytes32 channelId, uint256 expectedHeld) internal returns (Transaction[] memory) {
        bytes32 npk = bytes32(uint256(uint160(address(adjudicator))));
        CommitmentPreimage memory note = ArmadaNotes.usdcNote(tokenAddr, npk, uint120(value));

        // The mock pool must hold the token to hand it back on transact(): mint it there directly.
        normalToken.mint(address(_mockPool), value);

        // N1a: the channel's collateral reference is a SEPARATE commitment from the unshield's
        // own note, whose plaintext value is the NEW CUMULATIVE total (expectedHeld + value) --
        // depositFromNote verifies this against its own measured deposit math before trusting it.
        CommitmentPreimage memory collateral = ArmadaNotes.usdcNote(
            tokenAddr,
            npk,
            uint120(expectedHeld + value)
        );
        bytes32 collateralCommitment = bytes32(uint256(keccak256(abi.encode(collateral))));
        _mockPool.setPreimage(collateralCommitment, collateral);

        bytes32[] memory commitments = new bytes32[](1);
        commitments[0] = collateralCommitment;
        CommitmentPreimage[] memory publicOutputs = new CommitmentPreimage[](1);
        publicOutputs[0] = collateral;

        Transaction[] memory txs = new Transaction[](1);
        txs[0] = Transaction({
            proof: SnarkProof({
                a: G1Point(0, 0),
                b: G2Point([uint256(0), 0], [uint256(0), 0]),
                c: G1Point(0, 0)
            }),
            merkleRoot: bytes32(0),
            nullifiers: new bytes32[](0),
            commitments: commitments,
            boundParams: BoundParams({
                treeNumber: 0,
                minGasPrice: 0,
                unshield: UnshieldType.NORMAL,
                chainID: uint64(block.chainid),
                adaptContract: address(adjudicator),
                adaptParams: adjudicator.depositBinding(channelId, expectedHeld),
                commitmentCiphertext: new CommitmentCiphertext[](0),
                ownerField: bytes32(0),
                publicOutputs: publicOutputs
            }),
            unshieldPreimage: note
        });
        return txs;
    }
}
