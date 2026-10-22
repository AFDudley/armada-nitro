# stack/compose-jobs/armada-assets-e2e/

E11 stand-up (arn-d5a): the gate job that stands up a fresh Aave fixturenet,
proves it works, saves the warm base-layer snapshot for a later chunk, and
tears the running fixturenet down on exit.

- `run.sh` — the gate's entry point. Resolves `laconic-so`, checks that this
  directory's own files plus the compose job's yml and
  `env/gates/nitro-e2e/prepare.ts` all exist (`job_files_present`), stands up
  the fixturenet via `stack/scripts/fixturenet-new` under a deployment named
  `${ARMADA_ASSETS_DEP_NAME:-armada-assets-e2e}` (warm restore when a
  base-layer snapshot matches the current inputs, cold build + snapshot
  otherwise), then runs the `armada-assets-e2e` compose job
  (`../docker-compose-armada-assets-e2e.yml`). That job reuses
  `env/gates/nitro-e2e/prepare.ts`'s wallet and proof code and proves the
  Aave lending pool, `waUSDC` and USDC answer on the fixturenet RPC — read
  entirely from inside the job over the compose network, never by a
  host-side read of the deployment's root-owned `data/` directory — and
  reports that on its own stdout as `{"fixturenet_up": <bool>}`, which
  `run.sh` captures. `run.sh` prints one JSON summary line
  (`job_files_present`, `fixturenet_up`, `snapshot_present`) and sets an
  `EXIT` trap that tears down the running fixturenet and removes its
  deployment directory, unless `KEEP_FIXTURENET=1` is set, in which case the
  fixturenet is left running for a later chunk to reuse.
- `check-teardown.sh` — verifies, after a default (no `KEEP_FIXTURENET`) run
  of `run.sh` has exited, that no deployment is running, the deployment
  directory is gone, the warm snapshot still exists, and the snapshot cache
  (`~/deployments/.snapshots`) and the deployment directory are distinct,
  non-nested paths — so removing the deployment directory on exit can never
  remove the snapshot.
- `check-keep.sh` — runs `run.sh` with `KEEP_FIXTURENET=1`, verifies the
  fixturenet is still running once `run.sh` has exited, then removes it
  itself (this script owns that cleanup; nothing else does).

The compose job's yml lives one level up
(`stack/compose-jobs/docker-compose-armada-assets-e2e.yml`, where
`laconic-so run-job` looks for it) rather than in this directory, matching
every other job in `stack/compose-jobs/`.
