// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test, Vm} from 'forge-std/Test.sol';

/// @dev E16 S6: the forge suite itself enforces that the adjudicator source and
/// every Nitro framework source are free of ERC-4626 exchange-rate machinery, so
/// `forge test` (not an unexercised side script) is the thing that catches
/// violations. `testAdjudicatorSourceIsRateFree` reads the adjudicator source at the
/// path in the `ARN5DB_ADJUDICATOR_SRC` env var (default src/ArmadaNitroAdjudicator.sol).
/// The gate script points the suite at a scratch copy by setting that env var.
contract SettlementRateFree is Test {

    function setUp() public {}

    /// @dev The adjudicator source must import no ERC-4626 interface and call no
    /// exchange-rate function. When any forbidden name is present, this test FAILS.
    function testAdjudicatorSourceIsRateFree() public view {
        string memory defaultPath = "src/ArmadaNitroAdjudicator.sol";
        string memory path = vm.envOr("ARN5DB_ADJUDICATOR_SRC", defaultPath);
        string memory src = vm.readFile(path);
        uint256 total = _countForbiddenNames(src);
        assertEq(total, 0, 'adjudicator source must be free of ERC-4626 rate names');
    }

    /// @dev Every .sol file under src/nitro must be free of the same names.
    function testNitroSourceIsRateFree() public view {
        Vm.DirEntry[] memory entries = vm.readDir("src/nitro", 10, true);
        uint256 total = 0;
        for (uint256 i = 0; i < entries.length; i++) {
            string memory path = entries[i].path;
            if (_endsWith(path, ".sol")) {
                string memory src = vm.readFile(path);
                total += _countForbiddenNames(src);
            }
        }
        assertEq(total, 0, 'Nitro framework source must be free of ERC-4626 rate names');
    }

    /// @dev The five forbidden names this suite enforces (E16 S6).
    function _forbiddenNames() private pure returns (string[5] memory names) {
        names[0] = "ERC4626";
        names[1] = "IERC4626";
        names[2] = "convertToAssets";
        names[3] = "convertToShares";
        names[4] = "preview";
        return names;
    }

    /// Counts total (non-overlapping) occurrences of any forbidden name in `hay`.
    function _countForbiddenNames(string memory hay) private pure returns (uint256 count) {
        string[5] memory names = _forbiddenNames();
        for (uint256 i = 0; i < names.length; i++) {
            count += _countOccurrences(hay, names[i]);
        }
    }

    /// Returns the number of (non-recounted) occurrences of `needle` in `hay`.
    function _countOccurrences(string memory hay, string memory needle) private pure returns (uint256 count) {
        bytes memory hb = bytes(hay);
        bytes memory nb = bytes(needle);
        if (nb.length == 0 || nb.length > hb.length) return 0;
        for (uint256 i = 0; i + nb.length <= hb.length; i++) {
            bool isMatch = true;
            for (uint256 j = 0; j < nb.length; j++) {
                if (hb[i + j] != nb[j]) {
                    isMatch = false;
                    break;
                }
            }
            if (isMatch) {
                count += 1;
                i += (nb.length - 1);
            }
        }
    }

    /// Returns whether `hay` ends with `suffix`.
    function _endsWith(string memory hay, string memory suffix) private pure returns (bool) {
        bytes memory hb = bytes(hay);
        bytes memory sb = bytes(suffix);
        if (sb.length > hb.length) return false;
        for (uint256 i = 0; i < sb.length; i++) {
            if (hb[hb.length - sb.length + i] != sb[i]) return false;
        }
        return true;
    }
}
