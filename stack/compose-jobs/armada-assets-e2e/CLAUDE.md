# stack/compose-jobs/armada-assets-e2e/

arn-a18: the armada-assets-e2e gate job -- proves a fixturenet reaches ready
with the Aave pool, waUSDC, USDC and the adjudicator deployed, and that a
fresh build leaves a warm base-layer snapshot behind for the next run.

- `run.sh` -- the entry point. Stands up a fresh fixturenet with
  `stack/scripts/fixturenet-new` under a run-unique name, with `TMPDIR` set to
  the repo `.scratch` (the cold path builds + snapshots the base layer; the
  warm path restores it). Runs the `armada-assets-e2e` compose job via
  `laconic-so run-job` (never a direct host read of the deployment's own data
  directory -- gates and runners reach the fixturenet only via run-job and
  geth RPC) and reads back its `fixturenet_up` JSON field. Prints exactly one
  JSON line: `{"job_files_present", "fixturenet_up", "snapshot_present"}`.

- `armada-assets-e2e-job.py` -- runs inside the job container (the
  `cerc/armada-nitro-env` image, baked from this checkout's committed content
  -- `git archive HEAD` -- so a change here needs a commit before the next
  `run.sh` rebuilds the image). Two stages:
  1. Reuses the shared wallet + Groth16 proof code in
     `env/gates/nitro-e2e/prepare.ts` (copies it into
     `/src/armada-poc/scripts/gates/` and runs it with hardhat, the same
     pattern `../docker-compose-armada-nitro-e2e.yml` uses). A stage 1 failure
     is logged and swallowed -- it reuses the code but does not gate stage 2.
  2. Proves the fixturenet is ready: the Aave pool, waUSDC, USDC and the
     adjudicator all respond to a read-only `cast call` on the fixturenet RPC
     (`armada-fixturenet-geth:8545`, arn-e7a c3/c4). Prints one JSON line,
     `{"fixturenet_up": <true|false>}`.

The compose job definition itself is `../docker-compose-armada-assets-e2e.yml`
(top level, not in this folder) -- `laconic-so run-job <name>` looks up
`docker-compose-<name>.yml` directly under a deployment's `compose-jobs/`
directory, not in a subfolder, so the job's compose file cannot live beside
its scripts. The job name is registered in
`stack/stacks/armada-nitro-fixturenet/stack.yml`'s `jobs:` list.
