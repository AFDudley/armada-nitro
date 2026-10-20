// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test} from 'forge-std/Test.sol';
import {ArmadaNotes} from './helpers/ArmadaNotes.sol';

contract MiniPoseidonTest is Test {
    function test_placePoseidon() public {
        ArmadaNotes.placePoseidon(false);
        address t3 = ArmadaNotes.POSEIDON_T3;
        address t4 = ArmadaNotes.POSEIDON_T4;
        assertGt(t3.code.length, 0, "PoseidonT3 not linked");
        assertGt(t4.code.length, 0, "PoseidonT4 not linked");
    }
}
