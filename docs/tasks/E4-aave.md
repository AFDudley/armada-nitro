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

## Out of scope
Other reserves, borrowing, incentives, Lido, Armada.
