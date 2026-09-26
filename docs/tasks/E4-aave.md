# E4 Aave module

Depends on: E3b. Read `docs/ENVIRONMENT.md` §2, §4–§6, §8, and in `/src/aave-v3-origin` (tag `v3.7.0`):
`scripts/DeployAaveV3MarketBatched.sol`, `src/deployments/inputs/MarketInput.sol`, `DefaultMarketInput.sol`,
`src/deployments/contracts/procedures/AaveV3HelpersProcedureTwo.sol` (deploys `StataTokenFactory`),
`src/contracts/extensions/v3-config-engine/AaveV3ConfigEngine.sol` (`listAssets`), `src/contracts/extensions/stata-token/`.

## Goal
An Aave v3 market with a USDC reserve over the environment's Circle USDC, and the StataToken wrapper for it (`waUSDC`,
the shape of mainnet `waEthUSDC` `0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E`).

## Deliver
- `env/aave/EnvMarketInput.sol`: a `MarketInput` for this environment.
  - Owner and admins = the deployer. The wrapped native token = the weth module's address.
  - Market reference currency USD, 8 decimals. No flash-loan premium changes. No L2 features.
  - It reads addresses from environment variables set by the module; no address is hard-coded.
- `env/reconciler/modules/aave.py`:
  1. Runs `DeployAaveV3MarketBatched` with `EnvMarketInput`.
  2. On the fixturenet, deploys a `MockAggregator` with answer `1e8` as the USDC price feed. On Sepolia the feed is a
     target parameter (E8).
  3. Lists USDC through `AaveV3ConfigEngine.listAssets`, with reserve parameters equal to mainnet's USDC reserve.
     - Read them with `cast` from mainnet (`https://ethereum-rpc.publicnode.com`), Aave v3 Ethereum pool
       `getConfiguration(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)` and the reserve's interest-rate strategy, at a
       block you record.
     - Store the decoded values and the block in `env/aave/mainnet-usdc-reserve.json` with the commands used.
     - Supply and borrow caps: mainnet's.
  4. Creates the stata token with `StataTokenFactory.createStataTokens([usdc])`.
  - Record `poolAddressesProvider`, `pool`, `aUSDC`, `stataTokenFactory`, `usdcPriceFeed`, and `assets.waUSDC`.
  - Verify per §6.
  - Negative case: with one decoded reserve value changed in a scratch copy of the JSON, `--verify-only` fails naming
    that field.

## Acceptance (paste output)
```sh
~/bin/laconic-so deployment --dir <dep> run-job armada-env-reconcile     # aave: deployed; verify OK; gas
~/bin/laconic-so deployment --dir <dep> run-job armada-env-reconcile     # aave: present; deployer nonce unchanged
cast call <waUSDC> "asset()(address)" --rpc-url http://127.0.0.1:8545    # = usdc
cast call <aavePool> "getConfiguration(address)(uint256)" <usdc> --rpc-url http://127.0.0.1:8545
cast call 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 "getConfiguration(address)(uint256)" 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 --rpc-url https://ethereum-rpc.publicnode.com
```
Explain any bit of the two configuration words that differs (for example, the paused, frozen or isolation bits), with
evidence. A difference in LTV, liquidation threshold, liquidation bonus, decimals or reserve factor is a failure.

Also paste: deposit 100 USDC into `waUSDC` from the deployer, `balanceOf`, `redeem` all shares, and the final USDC
balance change.

## As built (findings from the run)
- `EnvMarketInput.sol` is not a literal `is MarketInput`: `MarketInput._getMarketInput` (the abstract this would
  override) is declared `pure`, and Solidity forbids widening an override's state mutability from `pure` to `view`
  ("Overriding function changes state mutability from 'pure' to 'view'", reproduced against this image's forge 1.8.3
  with a two-line contract). Reading `AAVE_WRAPPED_NATIVE_TOKEN` needs `vm.envAddress`, declared `view` in
  forge-std's `Vm.sol` -- so a `pure` override could not call it, and could not read an `immutable` set from one in a
  constructor either (immutable reads are also rejected from `pure` functions -- confirmed by the same repro
  technique). `EnvMarketInput.sol` instead exposes the same four-struct shape through a plain `view` function that
  `script/DeployMarket.s.sol` calls directly, feeding the same `AaveV3BatchOrchestration.deployAaveV3` that
  `DeployAaveV3MarketBatchedBase.run()` calls internally.
- `script/DeployMarket.s.sol` does not chain through `DeployAaveV3MarketBatchedBase.run()` at all (even though that
  base contract itself needs no edits to be driven): its post-deployment step calls `MetadataReporter`, which shells
  out via `vm.ffi` to `git`/`date`/`cast` and writes a timestamped report file -- convenience logging with no
  postcondition depending on it. The module's own script calls `AaveV3BatchOrchestration.deployAaveV3` directly (the
  same library call `DeployAaveV3MarketBatchedBase.run()` makes) and writes the exact addresses the manifest needs to
  `reports/aave-market.json` itself.
- `AaveV3ConfigEngine`'s `Listing.liqBonus` is the bonus **delta** above 100%, not the raw on-chain
  `liquidationBonus` (`CollateralEngine.sol`: `poolConfigurator.configureReserveAsCollateral(asset, ltv, liqThreshold,
  100_00 + updates[i].liqBonus)`). Passing mainnet's raw reserve value (10450) directly reverted every deploy attempt
  with `INVALID_LT_LB_RATIO` (7800 * (10000+10450)/10000 ≈ 159.5% > 100%). Fixed by passing `liquidationBonus -
  100_00` (450, i.e. a 4.50% bonus) from `env/aave/mainnet-usdc-reserve.json`'s raw value instead.
- `cast call`'s tuple decoder wraps a single-field struct return (`DataTypes.ReserveConfigurationMap`, the first field
  of `IPool.getReserveData`'s `ReserveDataLegacy`) in its own parentheses on that line (e.g.
  `(7237...420 [7.237e75])`), which needs stripping before parsing as a plain integer.
- Fixturenet gas on a fresh chain: aave 63,495,580. This run first recorded 52,933,580 on a chain where an earlier
  attempt had already deployed the five Aave logic libraries: `forge script` deploys linked libraries through the
  CREATE2 deployer (`0x4e59b448…`, predeployed by the genesis generator) and skips any that already exist. The
  difference (10,561,952 for BorrowLogic, SupplyLogic, PoolLogic, LiquidationLogic, FlashLoanLogic, plus 48 gas of
  calldata bytes) is not a reporting bug; `gasUsed` sums the receipts of what apply() broadcast. The same effect on
  usdc (SignatureChecker, 428,254) explains E3b's 7,580,525 versus 8,008,767 fresh. Gas figures in these docs are
  fresh-chain values.
- The fixturenet's listed USDC reserve configuration word came out byte-for-byte identical to mainnet's
  (`7237005577332262213973186574461225012726266025894705449840963830289119321420` both sides, read at fixturenet head
  and mainnet block 26057104) -- every bit matches, not just the five gated fields (ltv, liquidation threshold,
  liquidation bonus, decimals, reserve factor); no bit needed explaining.

## Out of scope
Other reserves, borrowing, incentives, Lido, Armada.
