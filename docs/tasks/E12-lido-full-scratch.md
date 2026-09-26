# E12 Lido: run the skipped scratch-deploy steps

Depends on: E9. Read the "As built" section of `docs/tasks/E5-lido.md`, `env/reconciler/modules/lido.py`,
`env/lido/steps-fixturenet.json`, `env/lido/deploy-params-fixturenet.toml`, and in the image `/src/lido-core`
(v4.0.1): `scripts/scratch/steps.json`, `scripts/scratch/steps/0135-deploy-staking-modules.ts`,
`0140-plug-staking-modules.ts`, `0150-transfer-roles.ts`, `lib/account.ts` (`impersonate`), and whatever
`0135` pulls from `lidofinance/community-staking-module`.

## Background
E5 skipped three of Lido's scratch-deploy steps:
- `0135` deploys the Community Staking Module and Curated Module v2 from a separate repository;
- `0140` plugs them into the staking router by impersonating the Aragon Agent (`hardhat_impersonateAccount`), which
  real geth does not support;
- `0150` transfers the OpenZeppelin admin roles to the Agent.

As a result, the deployer still holds admin roles on the oracle contracts. On mainnet those roles belong to Lido's DAO.

## Goal
The fixturenet's Lido matches a real deployment's shape: every scratch step runs, with no edit to lido-core or the
staking-module repository, and admin roles end with the DAO Agent.

## Deliver
- `0150` runs as published.
- `0135` runs as published. If the staking-module deploy hits its own `block_gas_limit` cap of 60M, set
  `FOUNDRY_BLOCK_GAS_LIMIT` in the environment; E5 reproduced a ~73.6M estimate. Pin the
  `community-staking-module` source it uses in `env/sources.lock.json`, and bake it into the image like other sources.
- `0140`'s effect is achieved without impersonation. The calls it makes as the Agent (read the step for the exact
  calls) go through a real Aragon vote, the same mechanism `lido.py` already uses to resume staking. That is our own
  step script, listed in `env/lido/steps-fixturenet.json` in place of `0140`. It must perform the same calls with the
  same arguments as `0140`; show a side-by-side of calls.
- `lido` verify adds these postconditions:
  - the staking router lists the same modules a scratch deploy on hardhat's in-process network produces (run that once
    inside the image to get the expected list and record it with provenance);
  - the deployer holds no `DEFAULT_ADMIN_ROLE` on the locator, AccountingOracle, either HashConsensus, or the staking
    router, and the Agent does.

  The existing postconditions stay: oracle unconfigured, `stEthPerToken` = 1e18, zero HashConsensus members.

## Acceptance (paste output)
On a fresh fixturenet, paste:
- the full reconcile, with lido gas and wall time;
- the second reconcile (no transactions);
- the staking-router module list next to the hardhat reference;
- the role checks.

Negative case: grant the deployer `DEFAULT_ADMIN_ROLE` on one oracle contract (through a DAO vote or the role holder)
and show that `--verify-only` fails naming it.

## Out of scope
Configuring oracles, running node operators, withdrawals.
