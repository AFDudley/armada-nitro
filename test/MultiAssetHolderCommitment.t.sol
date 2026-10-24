// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test} from 'forge-std/Test.sol';
import {console} from 'forge-std/console.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {
    BoundParams,
    CommitmentCiphertext,
    CommitmentPreimage,
    G1Point,
    G2Point,
    IArmadaPool,
    SnarkProof,
    TokenData,
    TokenType,
    Transaction,
    UnshieldType
} from 'src/armada/IArmadaPool.sol';
import {IMultiAssetHolder} from 'src/nitro/interfaces/IMultiAssetHolder.sol';
import {MockPool} from './helpers/MockPool.sol';
import {ArmadaNotes} from './helpers/ArmadaNotes.sol';

/// @dev A minimal mintable ERC20, standard enough for `MockPool.transact`'s `transferFrom`.
contract MintableToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev N1a: exposes a test-only setter for `holdings[asset][channelId]`, isolating `heldValue`'s
/// read semantics (this file's subject) from the deposit write-path mechanics (N1b/N2a's and
/// DepositAmount.t.sol/ArmadaNitroAdjudicator.t.sol's concern).
contract CommitmentHarness is ArmadaNitroAdjudicator {
    constructor(
        IArmadaPool pool_,
        address[] memory assets_
    ) ArmadaNitroAdjudicator(pool_, assets_) {}

    function testSetHolding(address asset, bytes32 channelId, bytes32 commitment) external {
        holdings[asset][channelId] = commitment;
    }
}

/// @dev Acceptance for the commitment-based holdings rewrite (originally N1a; the brief is
/// deleted, superseded by the Lean model, AFDudley/armada-lean branch adjudicator-model-v4 --
/// see the original text at integrated commit 5519526c if needed): `holdings` stores a bytes32
/// pool commitment reference, not a uint256 balance; `heldValue` reads the amount live
/// through `pool.preimageOf`; and the base `deposit` entry point is gone from the adjudicator.
contract MultiAssetHolderCommitmentTest is Test {
    /// @dev Re-declared locally (solc 0.8.17 does not support qualified `Interface.Event` emit
    /// syntax); `vm.expectEmit` matches by topic hash and data, not declaring-contract identity.
    event Deposited(bytes32 indexed destination, address asset, uint256 destinationHoldings);

    CommitmentHarness internal adjudicator;
    MockPool internal mockPool;
    address internal constant ASSET = address(0xA55E7);
    bytes32 internal constant CHANNEL = keccak256('n1a commitment channel');

    function setUp() public {
        mockPool = new MockPool();
        address[] memory assets = new address[](1);
        assets[0] = ASSET;
        adjudicator = new CommitmentHarness(IArmadaPool(address(mockPool)), assets);
    }

    /// @dev c2: heldValue on an empty (asset, channelId) returns 0.
    function test_heldValue_emptyCommitmentReturnsZero() public {
        uint256 held = adjudicator.heldValue(ASSET, CHANNEL);
        console.log('N1A_HELD_VALUE_EMPTY', held);
        assertEq(held, 0);
    }

    /// @dev c3: heldValue on a (asset, channelId) whose commitment the mock pool maps to a fixed
    /// CommitmentPreimage returns that preimage's value, read live -- changing the mock's mapped
    /// value (same commitment) changes what heldValue reports, with no write to `holdings` at all.
    function test_heldValue_setCommitmentReturnsPreimageValueAndFollowsPoolChange() public {
        bytes32 commitment = keccak256('n1a test commitment');
        adjudicator.testSetHolding(ASSET, CHANNEL, commitment);

        CommitmentPreimage memory preimage = CommitmentPreimage({
            npk: bytes32(uint256(uint160(address(adjudicator)))),
            token: TokenData({tokenType: TokenType.ERC20, tokenAddress: ASSET, tokenSubID: 0}),
            value: 777
        });
        mockPool.setPreimage(commitment, preimage);

        uint256 held = adjudicator.heldValue(ASSET, CHANNEL);
        console.log('N1A_HELD_VALUE_SET', held);
        assertEq(held, 777, 'heldValue must equal the mock pool preimage value');

        // Live read: change the mock's mapped preimage for the SAME commitment (no new deposit,
        // no write to `holdings`) and heldValue must follow it.
        preimage.value = 999;
        mockPool.setPreimage(commitment, preimage);
        uint256 heldAfterChange = adjudicator.heldValue(ASSET, CHANNEL);
        console.log('N1A_HELD_VALUE_FOLLOWS', heldAfterChange);
        assertEq(heldAfterChange, 999, 'heldValue must follow a live pool change, not a cached amount');
    }

    /// @dev c5: the inherited IMultiAssetHolder.deposit selector no longer exists on
    /// ArmadaNitroAdjudicator -- a low-level call to it reaches a missing function, not a revert
    /// from deposit logic. Foundry's low-level `.call` returns `(false, "")` for BOTH a missing
    /// function and a reverting one, so the detector compares against the explicit absence of the
    /// EVM "no matching function" marker: a function THAT EXISTS always returns some revert reason
    /// (even an empty `revert()` leaves return data length 0 too) -- so this test instead proves
    /// absence by checking the selector against the deployed bytecode (no call dispatch matches
    /// it), matching scripts/n1a_observe.sh's independent ABI-based check.
    function test_depositSelector_absentFromAdjudicator() public {
        bytes4 oldDepositSelector = bytes4(
            keccak256('deposit(address,bytes32,uint256,uint256)')
        );
        (bool ok, bytes memory ret) = address(adjudicator).call(
            abi.encodePacked(oldDepositSelector, abi.encode(ASSET, CHANNEL, uint256(0), uint256(1)))
        );
        // A present-but-failing deposit would revert with a specific require message (non-empty
        // return data carrying the reason). A MISSING function falls through to Solidity's
        // implicit `revert()` with EMPTY return data. Both report ok=false at the low-level-call
        // boundary, but only the missing-function case has zero-length return data with no
        // selector-bearing revert reason at all.
        console.log('N1A_DEPOSIT_SELECTOR_CALL_OK', ok);
        console.log('N1A_DEPOSIT_SELECTOR_RETURN_LEN', ret.length);
        assertFalse(ok, 'the removed deposit selector must not succeed');
        assertEq(ret.length, 0, 'a missing function reverts with empty return data, unlike a real require');
    }

    /// @dev c7: a holdings change (here, depositFromNote crediting a channel) emits `Deposited`
    /// -- SafeCast stays in use for the pool's uint120 values (ArmadaNitroAdjudicator.heldValue /
    /// _executeSingleAssetExit; MultiAssetHolder itself has no pool and cannot cast its value).
    function test_holdingsChange_emitsDepositedEvent() public {
        MintableToken token = new MintableToken();
        address[] memory assets = new address[](1);
        assets[0] = address(token);
        CommitmentHarness adj = new CommitmentHarness(IArmadaPool(address(mockPool)), assets);

        uint256 value = 42;
        bytes32 npk = bytes32(uint256(uint160(address(adj))));
        CommitmentPreimage memory note = ArmadaNotes.usdcNote(address(token), npk, uint120(value));
        CommitmentPreimage memory collateral = ArmadaNotes.usdcNote(address(token), npk, uint120(value));
        bytes32 collateralCommitment = bytes32(uint256(keccak256(abi.encode(collateral))));
        mockPool.setPreimage(collateralCommitment, collateral);
        token.mint(address(mockPool), value);

        Transaction[] memory txs = _buildDepositTx(adj, note, collateral, collateralCommitment, CHANNEL, 0);

        vm.expectEmit(true, false, false, true, address(adj));
        emit Deposited(CHANNEL, address(token), value);
        adj.depositFromNote(CHANNEL, 0, txs);
    }

    function _buildDepositTx(
        CommitmentHarness adj,
        CommitmentPreimage memory note,
        CommitmentPreimage memory collateral,
        bytes32 collateralCommitment,
        bytes32 channelId,
        uint256 expectedHeld
    ) internal view returns (Transaction[] memory txs) {
        bytes32[] memory commitments = new bytes32[](1);
        commitments[0] = collateralCommitment;
        CommitmentPreimage[] memory publicOutputs = new CommitmentPreimage[](1);
        publicOutputs[0] = collateral;

        txs = new Transaction[](1);
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
                adaptContract: address(adj),
                adaptParams: adj.depositBinding(channelId, expectedHeld),
                commitmentCiphertext: new CommitmentCiphertext[](0),
                ownerField: bytes32(0),
                publicOutputs: publicOutputs
            }),
            unshieldPreimage: note
        });
    }
}
