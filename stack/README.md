# Laconic-so Stacks

This directory contains the stack definitions used by the laconic-so orchestrator.

## Fixturenet

A single-node Proof-of-Stake devnet on upstream geth + lighthouse with every fork through
Osaka active at genesis.

### Commands

```sh
# 1. Generate the deployment spec (maps geth's 8545/8546 and the beacon's 5052 to
#    127.0.0.1 on the host). --config DEPLOYER_KEY=<key> puts the reconciler's deployer
#    key into the spec's `config:` section (on the fixturenet, anvil account 0) -- see
#    "Environment reconciler" below.
laconic-so --stack stack/stacks/armada-nitro-fixturenet deploy init \
  --map-ports-to-host localhost-same \
  --config DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --output ~/deployments/armada-fixturenet-e1-spec.yml

# 2. Create the deployment directory from the spec
laconic-so --stack stack/stacks/armada-nitro-fixturenet deploy create \
  --spec-file ~/deployments/armada-fixturenet-e1-spec.yml \
  --deployment-dir ~/deployments/armada-fixturenet-e1

# 3. Start the deployment
laconic-so deployment --dir ~/deployments/armada-fixturenet-e1 start

# Stop, preserving the genesis/chain data volumes (a subsequent `start` resumes the
# same chain instead of regenerating genesis):
laconic-so deployment --dir ~/deployments/armada-fixturenet-e1 stop

# Stop and wipe all volumes (forces genesis regeneration on next `start`):
laconic-so deployment --dir ~/deployments/armada-fixturenet-e1 stop --delete-volumes
```

The pod runs four services:
- `armada-fixturenet-genesis` - generates EL + CL genesis (idempotent: skips if
  `/data/metadata/genesis.json` and `genesis.ssz` already exist)
- `armada-fixturenet-geth` - upstream geth (EL, HTTP 8545, WS 8546, engine API 8551)
- `armada-fixturenet-beacon` - lighthouse beacon node (CL beacon, HTTP 5052)
- `armada-fixturenet-validator` - lighthouse validator client (4 validators)

Notes:
- `armada-fixturenet-geth`'s healthcheck (`eth_blockNumber` via BusyBox `wget`) gates
  `armada-fixturenet-beacon` and `armada-fixturenet-validator` startup via `depends_on`.
- The beacon needs `--allow-insecure-genesis-sync` and `--ignore-ws-check` because this
  is a freshly generated devnet with no existing peers/checkpoint to sync from.
- The genesis service computes `GENESIS_TIMESTAMP` at container start (`date +%s`) so the
  chain begins near "now" instead of the generator's default of the Unix epoch.
- geth's default `--miner.gasprice` (1,000,000 wei) is above this fixturenet's single-digit-wei
  base fee, so a `cast` transaction bidding the base fee never clears it and is never mined;
  `--miner.gasprice=1` fixes that.
- geth, the beacon and all 4 validators run under `cgroup_parent:
  ${FIXTURENET_SLICE}` with a `cpuset` pinning each to its own dedicated core
  (geth/beacon get 2 cores each, one validator per remaining core). The slice
  name and every cpuset are read from deployment config variables
  (`FIXTURENET_SLICE`, `GETH_CPUSET`, `BEACON_CPUSET`,
  `VALIDATOR_0_CPUSET`…`VALIDATOR_3_CPUSET`), each defaulting to this repo's
  reference host (kelce) values, so a different host retargets them at `deploy
  init` time without editing the compose file. This isolates fixturenet block
  production from other host load; the slice, its CPU reservation and the tmpfs
  below are set up by the ansible role in `ops/ansible/` (**see
  `ops/ansible/README.md`** for the outsider-facing setup, including how to pick
  CPUs and pass the config vars). See `docs/tasks/E12-lido-full-scratch.md`'s
  "As built" section for the full host-side rationale (validators cut from 64 to
  4, and why) and measurements.
- geth's HTTP server's default `IdleTimeout` (120s) closes a keep-alive connection that has
  sat idle for that long; a Lido scratch-deploy step (0135) runs an external `forge script
  --broadcast --slow` deploy for several minutes on a separate connection while Hardhat's own
  connection sits idle, so without this override the next JSON-RPC call after that step can
  fail with `EPIPE`. `armada-fixturenet-geth`'s command generates a `--config` file overriding
  only `[Node.HTTPTimeouts] IdleTimeout` (1 hour), leaving every other timeout/flag at its
  default.
- **Chain data lives in RAM, capped.** A size-capped tmpfs goes over the
  deployment's `data/` directory (the `ops/ansible/` role installs a systemd
  mount unit with `Options=size=3G` on `~/deployments/<name>/data`; mount it
  *after* `deploy create` and *before* `... start`). Two reasons: on
  kelce every disk-backed path shares devices with other heavy writers, and the chain's fsyncs waiting
  behind them caused reorgs and late blocks (measurements in `docs/tasks/E12-lido-full-scratch.md`'s
  "As built"); and the cap makes a forgotten fixturenet fill its RAM disk and die instead of growing on
  a shared filesystem. A reboot empties it; a fresh reconcile rebuilds the chain.
  geth runs with `--datadir.minfreedisk=64` (MB): its default floor (~2 GB free) would shut it down
  with a third of a 3 GB disk used. With the flag it uses the disk until 64 MB remain, then shuts down
  cleanly.

### Environment reconciler

`armada-env-reconcile` brings the fixturenet to the target state described by
`env/targets/fixturenet.json` (docs/ENVIRONMENT.md §3-§6) and writes a
manifest to the `armada_env` named volume, bind-mounted to
`<deployment>/data/armada_env` (it is declared in the fixturenet pod's
compose file so `deploy create` records it, per `docker-compose-armada-fixturenet.yml`).
The job sees it at `/env`.

The job needs the deployer key, which it takes from the deployment's own configuration --
never from the repository or the image. Put it in the spec's `config:` section with
`deploy init --config DEPLOYER_KEY=<key>` (on the fixturenet, anvil account 0; see
"Commands" above), which `deploy create` turns into the deployment's `config.env`, read by
every job as `$DEPLOYER_KEY`. On its first run, `armada-env-reconcile` writes that key to
`<state>/deployer.key` (mode 0600) if the file is not already there; later runs, and the
gate jobs (which share the same `armada_env` volume), find it already in place. A
deployment created without `DEPLOYER_KEY` in its config -- and with no key file placed by
hand -- fails the job, naming the missing variable. (The key can still be placed by hand
instead, e.g. for a deployment created before this option existed: write it directly to
`<state>/deployer.key` under the `armada_env` volume.)

```sh
laconic-so deployment --dir <deployment> run-job armada-env-reconcile
```

A second run sends no transactions and rewrites a byte-identical manifest
(`<deployment>/data/armada_env/manifest.json`). Setting `RECONCILER_VERIFY_ONLY=1`
in the environment before `run-job` checks postconditions read-only, without
deploying anything; `RECONCILER_ONLY=<module>` restricts the run to one module.

### Gates

Two jobs whose green result on the fixturenet defines "done" for the environment
(docs/ENVIRONMENT.md §7, `docs/tasks/E7-gates.md`). Both need `armada-env-reconcile` to have
completed a full deploy first (they read `/env/manifest.json`), and both run with
`network_mode: host`: `lib/sdk/chain-config.ts` inside armada-poc (used by both
`scripts/capture/e2e-armada-circuits.ts` and `env/gates/nitro-e2e/prepare.ts` for the Railgun
engine's merkle-tree scan) hardcodes `http://localhost:8545` for chain 31337 rather than reading
`HUB_RPC`; host networking is what makes `localhost:8545` inside the job container reach the
fixturenet, since geth's 8545 is published to `127.0.0.1:8545` on the host (`deploy init
--map-ports-to-host localhost-same` above).

```sh
laconic-so deployment --dir <deployment> run-job armada-env-verify
laconic-so deployment --dir <deployment> run-job armada-nitro-e2e
```

- **`armada-env-verify`**: `python3 -m reconciler --verify-only` against the manifest (every §6
  postcondition, read-only), then our own `env/gates/pool-e2e/pool-e2e.ts` against the network:
  shield 10 USDC, privately transfer 3 USDC and unshield 1 USDC, each with a real Groth16 proof
  (E10: replaces Armada's `scripts/capture/e2e-armada-circuits.ts`, whose step 4 -- yield -- needs
  Armada governance, their yield adapter and their mock Aave, none of which this environment
  deploys). Every step is checked on chain independently of the SDK: the `Shield`/`Transact`/
  `Unshield` event (decoded from a minimal ABI, not the SDK's own handling), and the payer's
  (shield) or recipient's (unshield) public USDC balance change, net of the pool's `shieldFee()`
  (50 bps) and `unshieldFee()` (always 0 on this pool version -- `TransactModule._transferTokenOut`
  pays the note's full value with no fee logic at all; `unshieldFee()`'s storage slot is
  commented "DEPRECATED -- unshield is free per spec" and has no setter). `pool-e2e.ts` still
  reads both fees live rather than hardcoding them.
- **`armada-nitro-e2e`**: two stages in one job.
  1. `env/gates/nitro-e2e/prepare.ts` (copied into `/src/armada-poc/scripts/gates/` so its
     `lib/sdk` imports resolve, then run with `npx hardhat run --network hub`): for two channels,
     a test-account wallet shields USDC and builds a real-proof unshield of an ERC20 note to the
     adjudicator (`UnshieldType.NORMAL`, `npk` = the adjudicator, `adaptContract`/`adaptParams`
     set via the engine's `TransactionBatch.setAdaptID`). Writes
     `/env/nitro-e2e/deposits.json`: per channel `{channelId, channelNonce, amount, calldata,
     proofTimeMs}` -- `channelId`/`amount`/`calldata` for `depositFromNote(channelId, 0, [tx])`;
     `channelNonce` (not literally in the brief's 3-field list) so stage 2 can reconstruct the
     exact `FixedPart` the proof's `channelId` hashes (`NitroUtils.getChannelId` cannot be
     inverted the other way).
  2. `script/FixturenetScenario.s.sol`: `LocalScenario.s.sol`'s cooperative close and force
     close against `/env/manifest.json` (not `deployments/31337*.json`), funded by
     `deposits.json`'s calldata sent by the test account instead of `ArmadaNotes.unshield`'s
     testing-mode notes. `CHALLENGE_DURATION` (default 30s, must match what stage 1 bound into
     the channelId) comes from the job environment. After the second channel's `challenge()`,
     `earlySettle()` (E10) attempts `transferAllAssets` immediately -- strictly inside the
     window, before any sleep -- and it must revert `'Channel not finalized.'`
     (`MultiAssetHolder._requireChannelFinalized`; proves the window is enforced, not just
     present). The job then sleeps out `CHALLENGE_DURATION` and `settle()` pays out the
     challenged outcome for real. Ends with `verified: both channels paid the user by shielding
     a note`, read from chain state and the pool's `Shield` logs.

Both jobs need Armada's compiled circuit build on disk (`/src/armada-circuits/build`) for
the artifacts `lib/sdk/armada-artifacts.ts` loads. It is baked into `cerc/armada-nitro-env`
at image build time (`stack/container-build/cerc-armada-nitro-env/Dockerfile`, pinned in
`env/sources.lock.json`'s `armada-circuits` entry); every job, including the first
`armada-env-reconcile`, only verifies the baked-in circuits' SHA-256 and never downloads
them (docs/tasks/E9-operability.md).

### Full sequence

```sh
laconic-so --stack stack/stacks/armada-nitro-fixturenet build-containers
laconic-so --stack stack/stacks/armada-nitro-fixturenet deploy init \
  --map-ports-to-host localhost-same \
  --config DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --output ~/deployments/armada-fixturenet-spec.yml
laconic-so --stack stack/stacks/armada-nitro-fixturenet deploy create \
  --spec-file ~/deployments/armada-fixturenet-spec.yml --deployment-dir ~/deployments/armada-fixturenet
laconic-so deployment --dir ~/deployments/armada-fixturenet start
laconic-so deployment --dir ~/deployments/armada-fixturenet run-job armada-env-reconcile
laconic-so deployment --dir ~/deployments/armada-fixturenet run-job armada-env-reconcile   # sends nothing
laconic-so deployment --dir ~/deployments/armada-fixturenet run-job armada-env-verify
laconic-so deployment --dir ~/deployments/armada-fixturenet run-job armada-nitro-e2e
```
