# E5 Lido module

Depends on: E3. Read `docs/ENVIRONMENT.md` §2, §4–§6, §8, and in `/src/lido-core` (tag `v4.0.1`): `scripts/dao-deploy.sh`,
`scripts/run-migration.sh`, `scripts/scratch/scratch-deploy.ts`, `scripts/scratch/steps.json`,
`scripts/scratch/steps/*.ts`, `scripts/scratch/deploy-params-testnet.toml`, and the repository's scratch-deploy docs.

## Goal
Lido core (stETH, wstETH, locator, oracles) deployed from scratch on the fixturenet, so that `wstETH` is Lido's real
contract. The oracle is **deployed but unconfigured**: no HashConsensus members, no reports, no price injection.

## Deliver
- `env/reconciler/modules/lido.py`:
  - Runs Lido's scratch deploy as published (`scripts/dao-deploy.sh`) with the environment variables and deploy
    parameters it documents.
    - The deployer is anvil account 0.
    - Use the fixturenet's genesis deposit contract, recorded by E1. If the scratch steps can only deploy a new
      deposit contract, report which step and let it deploy one.
    - Do not add oracle committee members, do not submit reports, do not set any price or share rate.
  - If staking is paused after the scratch deploy (Lido deploys paused), resume it with the role the scratch deploy
    grants the deployer or the DAO agent. Report the exact call.
  - Record `locator`, `stETH`, `wstETH`, `accountingOracle`, every `HashConsensus` address, and `assets.wstETH`.
  - Verify per §6.
  - Negative case: an oracle member added in a scratch deployment makes `--verify-only` fail on the "zero members"
    postcondition.
- The Lido deploy writes its own artifact file (`deployed-*.json`). Keep it in the state directory as
  `lido-deployed.json`.

## Acceptance (paste output)
```sh
~/bin/laconic-so deployment --dir <dep> run-job armada-env-reconcile     # lido: deployed; verify OK; gas
~/bin/laconic-so deployment --dir <dep> run-job armada-env-reconcile     # lido: present; deployer nonce unchanged
cast call <wstETH> "stETH()(address)" --rpc-url http://127.0.0.1:8545
cast call <wstETH> "stEthPerToken()(uint256)" --rpc-url http://127.0.0.1:8545       # 1000000000000000000
cast send <stETH> "submit(address)" 0x0000000000000000000000000000000000000000 --value 1ether --private-key <acct 3 key> --rpc-url http://127.0.0.1:8545
cast call <stETH> "balanceOf(address)(uint256)" <acct 3> --rpc-url http://127.0.0.1:8545
for h in <hashConsensus…>; do cast call $h "getMembers()(address[],uint256[])" --rpc-url http://127.0.0.1:8545; done   # empty
```
Report the Lido deploy's total gas and wall time.

## Out of scope
Configuring the oracle, running `lido-oracle`, staking modules beyond what the scratch deploy creates, withdrawals.
