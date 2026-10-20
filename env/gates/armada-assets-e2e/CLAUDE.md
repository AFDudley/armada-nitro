# env/gates/armada-assets-e2e/

E11 first chunk (arn-ced): the hub's Aave yield and redeem paths exercised through the
fixturenet's real Aave v3 market, demonstrated with on-chain evidence read by `cast`.
docs/tasks/E11-aave-lido-channels.md.

- `scenarios.ts` -- the gate's stage 1. Imports `env/gates/nitro-e2e/prepare.ts`'s wallet and
  proof code directly (rather than re-implementing it): the import runs prepare.ts's own `main()`
  (shield + real-proof unshield), writing deposits.json exactly as `armada-nitro-e2e` does. The
  job (stack/compose-jobs/armada-assets-e2e.yml) copies both files into the relative layout this
  import expects before running this script via hardhat.
- `run.sh` -- the gate's entry point. `--scenario <1|4> [--no-borrow] | --all`. Delegates to the
  shared job helper (`scripts/armada_job_helper.py`), which builds/selects the job's image, runs
  the `armada-assets-e2e` laconic-so job (passing `ASSETS_E2E_SCENARIO`/`ASSETS_E2E_NO_BORROW`),
  and prints the job's final JSON evidence line.

Scenario 1 (Aave yield) and its own on-chain steps (hub deposit into `waUSDC`, a second account's
Aave supply + LTV-75% borrow, redeem) run in `script/AssetsScenario.s.sol` (stage 2), driven by the
job; the job itself reads the yield evidence (`waUSDC.convertToAssets(1e6)`, the Aave pool's USDC
`liquidityIndex` via `getReserveData`) and the redeem's USDC balance change with `cast`, before and
after a real-block wait (>= 60s). Scenario 2, scenario 3, and discriminations (b)/(c) are out of
scope for this chunk. Lido's oracle stays unconfigured here: no members, no reports, no price
injection.

Runs against the operator-managed fixturenet via the `armada-assets-e2e` laconic-so job. The job
mounts the `armada_env` volume at `/env` (manifest + test-account keys), runs on the deployment's
own docker network (no host networking, arn-e7a c3), and reaches geth by the compose service name
(`armada-fixturenet-geth:8545`).
