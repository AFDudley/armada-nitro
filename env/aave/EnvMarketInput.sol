// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from 'forge-std/Vm.sol';
import 'aave-v3-origin/src/deployments/interfaces/IMarketReportTypes.sol';

/**
 * @title EnvMarketInput
 * @notice This environment's counterpart of aave-v3-origin's `MarketInput`/`DefaultMarketInput`
 * (src/deployments/inputs/MarketInput.sol, DefaultMarketInput.sol) -- docs/tasks/E4-aave.md.
 * Owner and every admin role are the deployer; the wrapped native token is this environment's
 * weth module address; the market reference currency is USD at 8 decimals; no flash-loan
 * premium is configured; no L2 flags are set (script/DeployMarket.s.sol leaves `flags.l2` at
 * its zero value). No address is hard-coded: `wrappedNativeToken` is read from the
 * `AAVE_WRAPPED_NATIVE_TOKEN` environment variable env/reconciler/modules/aave.py sets from the
 * manifest before invoking forge.
 *
 * @dev NOT a literal `is MarketInput`: `MarketInput._getMarketInput` (the abstract this would
 * override) is declared `pure`, and Solidity forbids widening an override's state mutability
 * from `pure` to `view` ("Overriding function changes state mutability from 'pure' to 'view'",
 * confirmed against this image's forge 1.8.3 with a two-line reproduction). Reading
 * `AAVE_WRAPPED_NATIVE_TOKEN` needs `vm.envAddress`, which forge-std's Vm.sol declares `view`
 * (`function envAddress(string calldata) external view returns (address)`) -- so a `pure`
 * override could not call it, and neither could it read an `immutable` set from one in a
 * constructor (immutable reads are also rejected from `pure` functions: same repro). Hard-coding
 * the weth address instead, to keep the literal `is MarketInput` shape, would violate the
 * brief's "no address is hard-coded". This contract instead exposes the same four-struct
 * shape (`Roles`, `MarketConfig`, `DeployFlags`, `MarketReport`) through a `view` function
 * that script/DeployMarket.s.sol calls directly and feeds into the same
 * `AaveV3BatchOrchestration.deployAaveV3` that `DeployAaveV3MarketBatchedBase.run()`
 * (aave-v3-origin's scripts/misc/DeployAaveV3MarketBatchedBase.sol) calls internally -- the
 * identical deployment procedure `scripts/DeployAaveV3MarketBatched.sol` composes with
 * `DefaultMarketInput`, just invoked without the `MarketInput` abstract type in between.
 */
abstract contract EnvMarketInput {
  Vm private constant vm = Vm(address(bytes20(uint160(uint256(keccak256('hevm cheat code'))))));

  function _getMarketInput(
    address deployer
  )
    internal
    view
    returns (
      Roles memory roles,
      MarketConfig memory config,
      DeployFlags memory flags,
      MarketReport memory deployedContracts
    )
  {
    roles.marketOwner = deployer;
    roles.poolAdmin = deployer;
    roles.emergencyAdmin = deployer;

    config.marketId = 'armada-nitro Fixturenet Market';
    config.providerId = 31337;
    config.oracleDecimals = 8; // market reference currency: USD, 8 decimals
    config.flashLoanPremium = 0; // no flash-loan premium changes
    config.wrappedNativeToken = vm.envAddress('AAVE_WRAPPED_NATIVE_TOKEN');

    return (roles, config, flags, deployedContracts);
  }
}
