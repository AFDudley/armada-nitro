# E8 Sepolia target

Status: scheduled last, immediately before production. E8 is a deployment rehearsal on a public network. It runs the
same code, reconciler and e2e jobs as the fixturenet, which holds every role that Circle, Lido and Aave hold on Sepolia.
So E8 proves no correctness property that the fixturenet jobs and E16 do not already prove.

Depends on: E7 green on the fixturenet. Prerequisite from the maintainer:
- a Sepolia deployer key file on kelce at `~/.config/armada-nitro/sepolia-deployer.key`;
- two test-account key files `~/.config/armada-nitro/sepolia-user{1,2}.key`, funded with Sepolia ETH and Circle
  Sepolia USDC (faucet.circle.com).

Required funding: the fixturenet gas table (E3a–E6) at current Sepolia gas prices, plus a 2× margin. Report the number
before sending anything.

Read `docs/ENVIRONMENT.md` §4–§8.

## Goal
Sepolia at the same target state as the fixturenet, by the same reconciler.
- Adopt what exists: WETH `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`; Circle USDC
  `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`; Circle CCTP v2 (demo3's `cctp` addresses in armada-poc
  `deployments/privacy-pool-hub-sepolia.json`); Lido wstETH `0xB82381A3fBD3FaFA77B3a7bE693342618240067b`; Armada
  demo3 pool `0x5f3324b47b3CFf937BB67C30B362898E193e5216` (deploy block `11588108`).
- Deploy the gaps: an Aave v3 market with a USDC reserve over Circle USDC plus its stata token (Aave's own Sepolia
  market uses a different USDC), and armada-nitro.

## Deliver
- `env/targets/sepolia.json`:
  - `adopt` entries for weth, usdc, cctp, lido, armada; `deploy` for aave and armada_nitro.
  - No `testAccounts` and no funding module.
  - The Aave USDC price feed = Chainlink's Sepolia USDC/USD aggregator. Take the address from Chainlink's published
    feed list, and verify on chain that `description()` = `USDC / USD` and `decimals()` = 8. Record both.
  - Group key: the target takes the group public key (X, Y) as parameters. For this run use the fixturenet scalar's
    key, and say so in the target file.
- Adopt-mode verification for each adopted module (§6 postconditions that are read-only).
  - Lido on Sepolia has a live oracle, so the "zero members" and `stEthPerToken = 1e18` postconditions apply only to
    deployed Lido. The adopt variant checks `wstETH.stETH()` and that `stEthPerToken()` > 0.
  - Report that difference in the module rather than weakening the deploy checks.
- A dry run first: `--dry-run` simulates with `forge script` (without `--broadcast`) and prints per-module gas.
- `env/manifests/sepolia.json` committed after the real run (addresses only).
- `armada-env-verify` and `armada-nitro-e2e` runnable against Sepolia with `TARGET=sepolia`, using the maintainer's
  key files mounted read-only. `prepare.ts` syncs from block `11588108` and must work within the public RPC's
  50,000-block `eth_getLogs` limit (chunk the scans, or report that the SDK does not).

## Acceptance (paste output)
1. The dry run with its gas table and cost at the current gas price. Stop here and report; the maintainer approves
   before broadcasting.
2. After approval: the reconcile output; a second reconcile with no transactions (deployer nonce unchanged);
   `armada-env-verify` (including Armada's e2e script on Sepolia); `armada-nitro-e2e` with Etherscan links for the
   deposit, close and challenge transactions.

## Out of scope
Mainnet. Changing adopted contracts. Configuring anything on Lido or Circle contracts on Sepolia.
