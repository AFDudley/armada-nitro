// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test} from 'forge-std/Test.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {IArmadaPool} from 'src/armada/IArmadaPool.sol';

/// @dev The ERC-4626 rate functions, called on an arbitrary vault. Used only to prove that the
/// bytecode scan below finds a rate call when one exists.
interface IRateVault {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

contract RateCaller {
    function rate(address vault) external view returns (uint256) {
        return IRateVault(vault).convertToAssets(1e18);
    }
}

/// @dev E16 S6 (design 15, I4): the adjudicator imports no ERC-4626 interface and calls no
/// exchange rate. The import check reads the compiler metadata of the adjudicator artifact, which
/// lists every source file the adjudicator compiles from (the transitive import closure). The call
/// check scans the deployed adjudicator bytecode for a PUSH4 of each ERC-4626 rate selector.
/// See docs/tasks/E16-adjudicator-hardening.md.
contract SettlementRateFreeTest is Test {
    string internal constant ARTIFACT = 'out/ArmadaNitroAdjudicator.sol/ArmadaNitroAdjudicator.json';
    bytes1 internal constant PUSH4 = 0x63;

    function test_adjudicatorImportClosure_hasNoERC4626Source() public {
        string[] memory sources = vm.parseJsonKeys(vm.readFile(ARTIFACT), '.metadata.sources');
        bool sawAdjudicator;
        bool sawHolder;
        for (uint256 i = 0; i < sources.length; i++) {
            assertEq(vm.indexOf(sources[i], '4626'), type(uint256).max, sources[i]);
            if (keccak256(bytes(sources[i])) == keccak256('src/ArmadaNitroAdjudicator.sol')) sawAdjudicator = true;
            if (keccak256(bytes(sources[i])) == keccak256('src/nitro/MultiAssetHolder.sol')) sawHolder = true;
        }
        // The metadata lists the closure the check claims to read.
        assertTrue(sawAdjudicator && sawHolder, 'artifact metadata does not list the adjudicator closure');
    }

    function test_adjudicatorBytecode_hasNoRateSelector() public {
        address[] memory assets = new address[](1);
        assets[0] = address(0xA55E7);
        bytes memory code = address(new ArmadaNitroAdjudicator(IArmadaPool(address(0x9001)), assets)).code;
        bytes4[6] memory selectors = _rateSelectors();
        for (uint256 i = 0; i < selectors.length; i++) {
            assertFalse(_hasPush4(code, selectors[i]), vm.toString(bytes32(selectors[i])));
        }
    }

    /// @dev The scan finds a rate call in a contract that makes one.
    function test_bytecodeScan_findsRateCall() public {
        assertTrue(_hasPush4(address(new RateCaller()).code, IRateVault.convertToAssets.selector));
    }

    function _rateSelectors() internal pure returns (bytes4[6] memory) {
        return [
            bytes4(keccak256('convertToAssets(uint256)')),
            bytes4(keccak256('convertToShares(uint256)')),
            bytes4(keccak256('previewDeposit(uint256)')),
            bytes4(keccak256('previewMint(uint256)')),
            bytes4(keccak256('previewRedeem(uint256)')),
            bytes4(keccak256('previewWithdraw(uint256)'))
        ];
    }

    function _hasPush4(bytes memory code, bytes4 selector) internal pure returns (bool) {
        for (uint256 i = 0; i + 4 < code.length; i++) {
            if (
                code[i] == PUSH4 &&
                code[i + 1] == selector[0] &&
                code[i + 2] == selector[1] &&
                code[i + 3] == selector[2] &&
                code[i + 4] == selector[3]
            ) return true;
        }
        return false;
    }
}
