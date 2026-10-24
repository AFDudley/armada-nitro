# stack/compose-jobs/armada-assets-e2e/

Gate that stands up a fresh Aave fixturenet, verifies it, saves a warm
base-layer snapshot for a later chunk, and tears the running fixturenet down
on exit (E11).

- `run.sh` — the gate. Warm-restores the base-layer snapshot (the same
  `stack/scripts/fixturenet-base-common.sh` helpers `fixturenet-new` and
  `fixturenet-base-snapshot` use) into `~/deployments/armada-assets-e2e`,
  starts the chain, and runs the base target
  (`env/targets/fixturenet-base.json`: weth, usdc, cctp, aave, lido, armada)
  with `--verify-only` so no transaction is sent. That verify pass is exactly
  "the Aave lending pool, waUSDC and USDC answer on the fixturenet RPC" --
  `env/reconciler/modules/aave.py`'s verify reads `getReserveData` off the
  pool and `asset()` off waUSDC; `usdc.py`'s verify reads
  `name()`/`symbol()`/`decimals()` off the USDC proxy. It then saves a warm
  base-layer snapshot (`stack/scripts/fixturenet-base-snapshot`) for a later
  chunk to restore, and prints one JSON line:
  `{"job_files_present","fixturenet_up","snapshot_present"}`. An `EXIT` trap
  stops the deployment and removes its directory; set `KEEP_FIXTURENET=1` to
  leave it running instead (the snapshot cache,
  `~/deployments/.snapshots` by default, is a sibling of the deployment
  directory, never inside it, so removing the deployment directory can never
  remove the snapshot). This gate never builds the base layer itself
  (arn-46d.1's rule, enforced repo-wide by a pre-commit hook on gates,
  compose-jobs and scripts): if no warm base snapshot exists yet it fails
  with a COLD message and exits non-zero.

  A later chunk's deposit/channel/payout scenario against this snapshot
  reuses `env/gates/nitro-e2e/prepare.ts`'s wallet + proof code (the Railgun
  wallet in `lib/sdk/wallet` and the Groth16 unshield proof in
  `lib/sdk/prover`); this stand-up-only gate does not shield, deposit, open a
  channel or build a proof itself.

- `check-teardown.sh` — runs `run.sh` on its default (no `KEEP_FIXTURENET`)
  path, then verifies no `armada-assets-e2e` deployment runs, its directory
  is gone, and the warm snapshot is still present and outside the deployment
  directory. Prints one JSON line.

- `check-keep.sh` — runs `run.sh` with `KEEP_FIXTURENET=1`, verifies the
  fixturenet is still running after `run.sh` exits, prints one JSON line,
  then tears the kept fixturenet down itself so the check leaks no state.
