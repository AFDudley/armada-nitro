// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test, Vm} from 'forge-std/Test.sol';
import {FROSTOffchain, SigningKey} from 'frost-secp256k1-evm/FROSTOffchain.sol';
import {HubCustodian} from 'src/HubCustodian.sol';

contract Target {
    uint256 public calls;

    function hit() external payable {
        calls++;
    }

    function fail() external pure {
        revert('target failed');
    }
}

contract HubCustodianTest is Test {
    using FROSTOffchain for SigningKey;

    uint256 internal constant GROUP_SCALAR =
        0xA4DDF31F7F32BA696F14CE50ECF3F21E3E100E83BDF47966E7B07468E9500B6E;
    uint256 internal constant REVOCATION_DELAY = 3 days;
    bytes4 internal constant MAGIC = 0x1626ba7e;

    SigningKey internal groupKey;
    HubCustodian internal custodian;
    Target internal target;

    function setUp() public {
        groupKey = FROSTOffchain.signingKeyFromScalar(GROUP_SCALAR);
        custodian = _deploy(groupKey);
        target = new Target();
    }

    function test_execute_performsCallAuthorizedByGroupKey() public {
        _execute(groupKey, address(target), abi.encodeCall(Target.hit, ()));
        assertEq(target.calls(), 1);
        assertEq(custodian.nonce(), 1);
    }

    /// @dev The fixture is a 2-of-3 threshold signature from the frost-secp256k1-evm crate over an
    /// operation hash computed in Rust (tools/frost-fixture).
    function test_execute_acceptsThresholdSignatureFromFrostCrate() public {
        string memory json = vm.readFile('test/fixtures/frost-2of3.json');
        address at = vm.parseJsonAddress(json, '.custodian');
        address targetAt = vm.parseJsonAddress(json, '.target');
        deployCodeTo(
            'HubCustodian.sol:HubCustodian',
            abi.encode(
                vm.parseJsonUint(json, '.groupKeyX'),
                vm.parseJsonUint(json, '.groupKeyY'),
                REVOCATION_DELAY
            ),
            at
        );
        deployCodeTo('HubCustodian.t.sol:Target', targetAt);
        HubCustodian thresholdCustodian = HubCustodian(payable(at));
        bytes memory data = abi.encodeCall(Target.hit, ());
        assertEq(
            thresholdCustodian.operationHash(0, targetAt, 0, data),
            vm.parseJsonBytes32(json, '.operationHash'),
            'operation hash matches the Rust encoding'
        );

        thresholdCustodian.execute(
            targetAt,
            0,
            data,
            HubCustodian.GroupSignature(
                vm.parseJsonUint(json, '.commitmentX'),
                vm.parseJsonUint(json, '.commitmentY'),
                vm.parseJsonUint(json, '.z')
            )
        );
        assertEq(Target(targetAt).calls(), 1);
    }

    function test_execute_rejectsReplayedSignature() public {
        bytes memory data = abi.encodeCall(Target.hit, ());
        HubCustodian.GroupSignature memory sig = _sign(groupKey, custodian, 0, address(target), data);
        custodian.execute(address(target), 0, data, sig);

        vm.expectRevert(HubCustodian.InvalidGroupSignature.selector);
        custodian.execute(address(target), 0, data, sig);
    }

    function test_execute_rejectsSignatureForAnotherCustodian() public {
        HubCustodian other = _deploy(groupKey);
        bytes memory data = abi.encodeCall(Target.hit, ());
        HubCustodian.GroupSignature memory sig = _sign(groupKey, other, 0, address(target), data);

        vm.expectRevert(HubCustodian.InvalidGroupSignature.selector);
        custodian.execute(address(target), 0, data, sig);
    }

    function test_execute_rejectsSignatureByAnotherKey() public {
        SigningKey otherKey = FROSTOffchain.signingKeyFromScalar(uint256(keccak256('other group')));
        bytes memory data = abi.encodeCall(Target.hit, ());
        HubCustodian.GroupSignature memory sig = _sign(otherKey, custodian, 0, address(target), data);

        vm.expectRevert(HubCustodian.InvalidGroupSignature.selector);
        custodian.execute(address(target), 0, data, sig);
    }

    function test_execute_bubblesTargetRevertAndKeepsNonce() public {
        bytes memory data = abi.encodeCall(Target.fail, ());
        HubCustodian.GroupSignature memory sig = _sign(groupKey, custodian, 0, address(target), data);

        vm.expectRevert(bytes('target failed'));
        custodian.execute(address(target), 0, data, sig);
        assertEq(custodian.nonce(), 0);
    }

    function test_administration_onlyThroughGroupAuthorizedExecute() public {
        vm.expectRevert(HubCustodian.OnlySelf.selector);
        custodian.authorizeDelegate(address(0xBEEF));
        vm.expectRevert(HubCustodian.OnlySelf.selector);
        custodian.rotateGroupKey(1, 2);
    }

    function test_isValidSignature_acceptsOnlyActiveDelegates() public {
        (address delegate, uint256 delegateKey) = makeAddrAndKey('delegate');
        (, uint256 strangerKey) = makeAddrAndKey('stranger');
        bytes32 digest = keccak256('state');

        assertEq(custodian.isValidSignature(digest, _ecdsa(delegateKey, digest)), bytes4(0xffffffff));
        _execute(groupKey, address(custodian), abi.encodeCall(HubCustodian.authorizeDelegate, (delegate)));
        assertEq(custodian.isValidSignature(digest, _ecdsa(delegateKey, digest)), MAGIC);
        assertEq(custodian.isValidSignature(digest, _ecdsa(strangerKey, digest)), bytes4(0xffffffff));
        assertEq(custodian.isValidSignature(digest, hex'00'), bytes4(0xffffffff));
    }

    function test_revokeDelegate_takesEffectAfterRevocationDelay() public {
        (address delegate, uint256 delegateKey) = makeAddrAndKey('delegate');
        bytes32 digest = keccak256('state');
        _execute(groupKey, address(custodian), abi.encodeCall(HubCustodian.authorizeDelegate, (delegate)));

        vm.expectEmit(address(custodian));
        emit HubCustodian.DelegateRevocationScheduled(delegate, uint64(block.timestamp + REVOCATION_DELAY));
        _execute(groupKey, address(custodian), abi.encodeCall(HubCustodian.revokeDelegate, (delegate)));

        vm.warp(block.timestamp + REVOCATION_DELAY - 1);
        assertEq(custodian.isValidSignature(digest, _ecdsa(delegateKey, digest)), MAGIC);
        vm.warp(block.timestamp + 1);
        assertEq(custodian.isValidSignature(digest, _ecdsa(delegateKey, digest)), bytes4(0xffffffff));
    }

    function test_rotateGroupKey_retiresOldKey() public {
        SigningKey newKey = FROSTOffchain.signingKeyFromScalar(uint256(keccak256('new group')));
        Vm.Wallet memory wallet = vm.createWallet(newKey.asScalar());
        _execute(
            groupKey,
            address(custodian),
            abi.encodeCall(HubCustodian.rotateGroupKey, (wallet.publicKeyX, wallet.publicKeyY))
        );

        bytes memory data = abi.encodeCall(Target.hit, ());
        HubCustodian.GroupSignature memory oldSig = _sign(groupKey, custodian, 1, address(target), data);
        vm.expectRevert(HubCustodian.InvalidGroupSignature.selector);
        custodian.execute(address(target), 0, data, oldSig);

        _execute(newKey, address(target), data);
        assertEq(target.calls(), 1);
    }

    function test_constructor_rejectsPointOffCurve() public {
        vm.expectRevert(HubCustodian.InvalidGroupKey.selector);
        new HubCustodian(1, 2, REVOCATION_DELAY);
    }

    function _deploy(SigningKey key) internal returns (HubCustodian) {
        Vm.Wallet memory wallet = vm.createWallet(key.asScalar());
        return new HubCustodian(wallet.publicKeyX, wallet.publicKeyY, REVOCATION_DELAY);
    }

    function _execute(SigningKey key, address to, bytes memory data) internal {
        custodian.execute(to, 0, data, _sign(key, custodian, custodian.nonce(), to, data));
    }

    function _sign(
        SigningKey key,
        HubCustodian on,
        uint256 nonce,
        address to,
        bytes memory data
    ) internal returns (HubCustodian.GroupSignature memory) {
        (uint256 rx, uint256 ry, uint256 z) = key.createSignature(on.operationHash(nonce, to, 0, data));
        return HubCustodian.GroupSignature(rx, ry, z);
    }

    function _ecdsa(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
