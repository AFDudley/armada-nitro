// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test, console2} from 'forge-std/Test.sol';
import {ArmadaNitroAdjudicator} from 'src/ArmadaNitroAdjudicator.sol';
import {IMultiAssetHolder} from 'src/nitro/interfaces/IMultiAssetHolder.sol';
import {INitroAdjudicator} from 'src/nitro/interfaces/INitroAdjudicator.sol';
import {WatchtowerPerAssetSetup} from '../script/WatchtowerPerAssetSetup.s.sol';
import {WatchtowerScenario} from '../script/WatchtowerScenario.s.sol';

/**
 * @notice arn-df2 (E16 S4, request clauses c1/c2): proves `WatchtowerScenario.s.sol`'s
 * `respond()`/`settleStale()` pay every asset of a two-asset channel through its own
 * `transfer(assetIndex, ...)` call, and NEVER through the combined `concludeAndTransferAllAssets`
 * / `transferAllAssets` call -- in BOTH a run where that combined call would have succeeded (the
 * second asset's token transfers fine) and one where it would not (the second asset's token
 * always reverts on `transfer`, so a single all-assets call covering both assets would revert as
 * a whole; see test/PerAssetExitS4.t.sol's `test_transferAllAssets_revertsAsWhole_whenPairedTokenReverts`).
 *
 * Drives the REAL `script/WatchtowerPerAssetSetup.s.sol` and `script/WatchtowerScenario.s.sol`
 * contracts directly (as plain Solidity calls, not via a separate `forge script` process): a
 * `forge script --broadcast` run aborts the whole script if ANY transaction it queues for
 * broadcast would revert on-chain -- even one wrapped in a low-level `.call()` -- which would
 * make it impossible to exercise the "combined call infeasible" arm at all. Calling the same
 * contracts' external functions directly from a `forge test` sidesteps that: `vm.broadcast` acts
 * like a prank (no broadcast-queue dry-run), so a per-asset `transfer` that reverts on-chain
 * leaves the OTHER asset's payout, and the rest of the scenario, unaffected.
 *
 * `vm.expectCall(target, data, count)` asserts an EXACT number of calls matching `data` (a
 * selector prefix matches any arguments) were made by the time the test ends -- including calls
 * that themselves revert, since the EVM call-tracing it relies on happens regardless of whether
 * the traced call's own execution succeeds. That is exactly "committed" for this check: each
 * `transfer(assetIndex, ...)` instance in the loop IS its own separate call/transaction, whether
 * or not that asset's own token accepts the transfer.
 */
contract WatchtowerPerAssetPayoutCheckTest is Test {
    uint256 internal constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant USER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant HUB_KEY = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant CHALLENGE_DURATION = 5;
    uint256 internal constant STATE_N_USER = 1_000_000;
    uint256 internal constant STATE_N1_USER = 2_000_000;
    uint256 internal constant HUB_RESERVE = 500_000;
    uint256 internal constant SECOND_ASSET_AMOUNT = 300_000;

    function test_respond_perAssetPayout_whenCombinedWouldSucceed() public {
        _checkRespond(false, 'respond-feasible');
    }

    function test_respond_perAssetPayout_whenCombinedWouldRevert() public {
        _checkRespond(true, 'respond-infeasible');
    }

    function test_settleStale_perAssetPayout_whenCombinedWouldSucceed() public {
        _checkSettleStale(false, 'settlestale-feasible');
    }

    function test_settleStale_perAssetPayout_whenCombinedWouldRevert() public {
        _checkSettleStale(true, 'settlestale-infeasible');
    }

    function _checkRespond(bool secondAssetReverts, string memory label) internal {
        (WatchtowerScenario scenario, ArmadaNitroAdjudicator adjudicator) = _deployAndFund(
            secondAssetReverts,
            label
        );
        scenario.openAndChallenge(0);

        vm.expectCall(
            address(adjudicator),
            abi.encodeWithSelector(INitroAdjudicator.concludeAndTransferAllAssets.selector),
            0
        );
        vm.expectCall(
            address(adjudicator),
            abi.encodeWithSelector(INitroAdjudicator.transferAllAssets.selector),
            0
        );
        vm.expectCall(address(adjudicator), abi.encodeWithSelector(IMultiAssetHolder.transfer.selector), 2);

        scenario.respond(0);

        // Sanity (arn-5a6 / design 15 I5): the first (good) asset is paid regardless; the second
        // asset is paid too when its token cooperates, and left unpaid (not the whole channel)
        // when it does not -- never an all-or-nothing failure.
        assertEq(adjudicator.holdings(_usdc(scenario), _channelId(scenario)), 0);
    }

    function _checkSettleStale(bool secondAssetReverts, string memory label) internal {
        (WatchtowerScenario scenario, ArmadaNitroAdjudicator adjudicator) = _deployAndFund(
            secondAssetReverts,
            label
        );
        scenario.openAndChallenge(0);
        vm.warp(block.timestamp + CHALLENGE_DURATION + 1);

        vm.expectCall(
            address(adjudicator),
            abi.encodeWithSelector(INitroAdjudicator.concludeAndTransferAllAssets.selector),
            0
        );
        vm.expectCall(
            address(adjudicator),
            abi.encodeWithSelector(INitroAdjudicator.transferAllAssets.selector),
            0
        );
        vm.expectCall(address(adjudicator), abi.encodeWithSelector(IMultiAssetHolder.transfer.selector), 2);

        scenario.settleStale(0);

        assertEq(adjudicator.holdings(_usdc(scenario), _channelId(scenario)), 0);
    }

    /// @dev Deploys a fresh two-asset fixture (script/WatchtowerPerAssetSetup.s.sol's
    /// `setup(bool)`, unmodified) into its own scratch manifest/deposits/keys files, and points
    /// `scenario`'s env at them so `openAndChallenge`/`respond`/`settleStale` run unmodified.
    function _deployAndFund(
        bool secondAssetReverts,
        string memory label
    ) internal returns (WatchtowerScenario scenario, ArmadaNitroAdjudicator adjudicator) {
        string memory scratch = string.concat('deployments/check-arn-df2-', label);
        vm.createDir(scratch, true);
        vm.setEnv('DEPLOYER_KEY', vm.toString(DEPLOYER_KEY));
        vm.setEnv('USER_KEY', vm.toString(USER_KEY));
        vm.setEnv('HUB_KEY', vm.toString(HUB_KEY));
        vm.setEnv('CHALLENGE_DURATION', vm.toString(CHALLENGE_DURATION));
        vm.setEnv('STATE_N_USER', vm.toString(STATE_N_USER));
        vm.setEnv('STATE_N1_USER', vm.toString(STATE_N1_USER));
        vm.setEnv('HUB_RESERVE', vm.toString(HUB_RESERVE));
        vm.setEnv('SECOND_ASSET_AMOUNT', vm.toString(SECOND_ASSET_AMOUNT));
        vm.setEnv('MANIFEST_PATH', string.concat(scratch, '/manifest.json'));
        vm.setEnv('DEPOSITS_PATH', string.concat(scratch, '/deposits.json'));
        vm.setEnv('KEYS_DIR', scratch);

        WatchtowerPerAssetSetup setupScript = new WatchtowerPerAssetSetup();
        // This fixture places the Poseidon precompile via `vm.rpc('anvil_setCode', ...)`
        // (needed so a REAL anvil node backing `--fork-url` has the bytecode too, not just this
        // run's forked EVM state), which needs a live RPC behind an active fork. Skip (not fail)
        // under a plain `forge test` with no `--fork-url`: this file is driven by
        // scripts/check-respond-per-asset-payout.sh / scripts/check-settlestale-per-asset-payout.sh,
        // which always supply one.
        try setupScript.setup(secondAssetReverts) returns (address secondAssetAddr) {
            vm.setEnv('SECOND_ASSET', vm.toString(secondAssetAddr));
        } catch (bytes memory) {
            vm.skip(true);
        }

        scenario = new WatchtowerScenario();
        string memory manifest = vm.readFile(string.concat(scratch, '/manifest.json'));
        adjudicator = ArmadaNitroAdjudicator(vm.parseJsonAddress(manifest, '.armadaNitro.adjudicator'));
    }

    function _usdc(WatchtowerScenario scenario) internal view returns (address) {
        string memory manifest = vm.readFile(_manifestPathOf(scenario));
        return vm.parseJsonAddress(manifest, '.armada.usdc');
    }

    function _channelId(WatchtowerScenario) internal view returns (bytes32) {
        bytes32 id;
        // Re-derive the channel id the same way openAndChallenge/respond/settleStale do: the
        // deposits file's first (only) entry's channelId.
        string memory depositsPath = vm.envString('DEPOSITS_PATH');
        string memory json = vm.readFile(depositsPath);
        id = vm.parseJsonBytes32(json, '.deposits[0].channelId');
        return id;
    }

    function _manifestPathOf(WatchtowerScenario) internal view returns (string memory) {
        return vm.envString('MANIFEST_PATH');
    }
}
