# env/gates/armada-sol/

The scenarios of PoolSol, the pool contract that armada-laconic-mono emits from Lean
(env/armada-sol/README.md), on the fixturenet.

- `scenarios.ts` (hardhat, ethers 6, Armada's SDK) — one scenario for each external function of
  PoolSol: `setFeeRatio`, `shield`, `transact`, `transactOwned`. Each result is checked on chain:
  events, storage by solc's layout, and USDC balances. The `transact` scenarios use a real Groth16
  proof that Armada's SDK makes against Armada's own pool. Prints one line
  `VERDICT <function> PASS|FAIL <detail>` for each function, and exits non-zero when one is FAIL.
  The module comment states the expected FAIL verdicts and their causes.

The `armada-sol-scenario` job (`stack/compose-jobs/docker-compose-armada-sol-scenario.yml`) copies
`scenarios.ts` into `/src/armada-poc/scripts/gates/` and runs it there, so that its relative
imports of `lib/sdk` resolve. The pool comes from the manifest's `armadaSol` entry, which the
`armada_sol` reconciler module (`env/reconciler/modules/armada_sol.py`) writes.
