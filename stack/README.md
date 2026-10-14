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
  below are set up and continuously enforced by the `host_cpu_policy` role in
  **laconic-tech-ops `infra/kelce`** (applied by ansible-pull; **see that repo's
  `infra/kelce/README.md`** for the host CPU partition, how to pick cores, and
  how the per-service cpusets must stay inside the reserved half). See
  `docs/tasks/E12-lido-full-scratch.md`'s
  "As built" section for the full host-side rationale (validators cut from 64 to
  4, and why) and measurements.
- geth's HTTP server's default `IdleTimeout` (120s) closes a keep-alive connection that has
  sat idle for that long; a Lido scratch-deploy step (0135) runs an external `forge script
  --broadcast --slow` deploy for several minutes on a separate connection while Hardhat's own
  connection sits idle, so without this override the next JSON-RPC call after that step can
  fail with `EPIPE`. `armada-fixturenet-geth`'s command generates a `--config` file overriding
  only `[Node.HTTPTimeouts] IdleTimeout` (1 hour), leaving every other timeout/flag at its
  default.
- **Chain data lives in RAM, capped.** `stack/scripts/fixturenet-new` mounts a size-capped tmpfs
  (`FIXTURENET_DATA_SIZE`, default `3G`, mode `0700`) over the deployment's `data/` directory after
  `deploy create` and before `start`. On disk, `data/` is only an empty mountpoint: the script removes
  the empty volume directories that `deploy create` leaves there, and refuses to mount if `data/` on
  disk holds any file. Two reasons for RAM: on kelce every disk-backed path shares devices with other
  heavy writers, and the chain's fsyncs waiting behind them caused reorgs and late blocks
  (measurements in `docs/tasks/E12-lido-full-scratch.md`'s "As built"); and the cap makes a forgotten
  fixturenet fill its RAM disk and die instead of growing on a shared filesystem.
  Nothing mounts the RAM disk at boot, and every chain service has `restart: "no"`. A host reboot
  therefore loses the chain (accepted 2026-09-27), starts nothing, and writes nothing to disk.
  `stack/scripts/fixturenet-recover <name>` brings the fixturenet back: it stops the deployment and
  runs `fixturenet-new`, which mounts the RAM disk and restores the base snapshot for the current
  inputs from `~/deployments/.snapshots` (warm path), then deploys `armada_nitro` and `funding`.
  When no snapshot matches the current inputs, it builds and snapshots the base layer instead (cold
  path, about 25 min). Chain state after the base snapshot is lost either way.
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

### Environment image

`cerc/armada-nitro-env:local` (`stack/container-build/cerc-armada-nitro-env/`,
built with BuildKit) bakes in every pinned upstream source, this repo's compiled
contracts and Armada's circuit build, so jobs run fully offline. The Dockerfile
is split into one BuildKit stage per input so a change invalidates only what it
affects:

- **`toolchain`** -- the shared base: Debian + git/jq/python, `just`, Foundry
  v1.8.3, Node 22 + yarn 4.9.2.
- **`src-<name>`** -- one stage per `env/sources.lock.json` `sources[]` entry.
  Its repo and commit arrive as `--build-arg` (`build.sh` reads them from the
  lock with `jq`; `clone-source.sh` fails the build if either is empty), so a
  source's layers are keyed only by that source's pin. A byte change to
  `env/sources.lock.json` that changes no pin rebuilds nothing; changing one
  source's pin rebuilds only that stage. Each stage runs that project's own
  install/build (`yarn`/`npm` + `forge build` + `hardhat compile` as needed);
  the CSM stage additionally does `checkout -B develop` + `just deps`.
- **`circuits`** -- Armada's circuit build, keyed only by the `armada-circuits`
  pins (a lock file is synthesised from the ARGs), so nothing else invalidates it.
- **`contracts`** -- only this repo's Foundry inputs (`foundry.toml`,
  `foundry.lock`, `src/`, `script/`, `test/`, `lib/`; remappings live in
  `foundry.toml`) + `forge build`, so `env/` churn never recompiles contracts.
- final image -- copies each `/src/<name>`, merges the HOME caches the stages
  populated (`~/.svm` solc, `~/.yarn/berry` Yarn global cache, hardhat
  compilers) so job-time compiles are offline, sets the system git
  `url.insteadOf` for CSM, copies the repo + the `contracts` build output + the
  circuits, and verifies every `/src/<name>` HEAD equals its pin.

`build.sh` also tags the `toolchain`, each `src-<name>` and the `circuits` stage
(extra `--target` builds that reuse the shared layers, so they only add tags), so
their image IDs are available to the base-snapshot cache key below.

### Base-layer snapshot cache

A full `armada-env-reconcile` takes ~25 min, ~24 of which deploy third-party
infrastructure that never changes unless its pinned inputs do: `weth`, `usdc`,
`cctp`, `aave`, `lido` and the `armada` pool. Those six modules plus the chain
itself are the **base layer**. We build it once, snapshot only its **execution
layer**, and restore that into new deployments -- regenerating the consensus
genesis at restore time -- so a new fixturenet only deploys `armada_nitro` +
`funding` (~1 min) on top.

**What is snapshotted, and why only the execution layer.** An earlier version
tarred the *whole* stopped chain -- every `data/` volume, consensus layer
included -- and restored it to resume the same chain. That only works if the
restore happens soon: a beacon restored hours later wakes up with its head slot
frozen far behind the current wall-clock slot, and a single node with no peers
never catches up (head stuck while `current_slot` runs ahead, late blocks
orphaned). Since snapshots are normally restored hours or days later, that cache
was broken.

So we snapshot only the **execution layer**, which has no wall-clock notion:
`geth_data` (geth's full data dir -- keeping all history and block numbers, which
Lido's MiniMe DAO-token checkpoints depend on, so we must **not** bake state into
a fresh EL genesis), the `armada_env` state (manifest/keys), the EL genesis
(`armada_fixturenet_genesis/metadata/genesis.json` + `jwt/jwtsecret`), and the EL
**head block** recorded as JSON (`eth_getBlockByNumber("latest", false)`) while
block production is halted, so it is exactly geth's final on-disk head. It
compresses to a few MB. It does **not** contain the beacon, the four validators
or the consensus genesis (`genesis.ssz`).

**How a restore avoids the slot gap.** On restore we put geth's data back and
regenerate only the consensus genesis, as a **shadow fork** on the recorded head
with `GENESIS_TIMESTAMP=now`: the genesis container (ethpandaops
`ethereum-genesis-generator`) finds `genesis.json` already present so it skips EL
generation, and finds the recorded head at `/data/shadow-fork-block.json`, which
`fixturenet-new` points its `SHADOW_FORK_FILE` at (→ `eth-genesis-state-generator
--shadow-fork-block`), so the new beacon genesis's `latest_execution_payload_header`
is geth's current head. The beacon and validators start with empty data dirs; the
new genesis has a fresh `genesis_validators_root`, so their slashing-protection
DBs start clean (same mnemonic, same four validators). The beacon therefore
starts at **slot 0 on geth's head** and produces geth's `head + 1` next -- no slot
gap, however old the snapshot is. This is the same idea as stack-orchestrator's
`cerc-fixturenet-eth-lighthouse` (`run-cl.sh` → `genesis/cl/reset_genesis_time.sh`),
which `lcli change-genesis-time`s the beacon genesis to now on every fresh start;
we extend it with a shadow fork because our chain already has execution history.

**The base target.** `env/targets/fixturenet-base.json` names only `network` +
the six base modules. `fixturenet-new` copies it into the `armada_env` volume
(seen as `/env` in the job) and selects it with the reconciler's existing
`RECONCILER_TARGET` variable; the image's default full target
(`env/targets/fixturenet.json`) is untouched, so the later full reconcile finds
the base modules already `present, 0` and deploys only `armada_nitro` + `funding`.

**Cache key.** A 16-hex sha256 over everything that determines the base chain,
computed by `stack/scripts/base-key.py` (called from
`fixturenet-base-common.sh`). Every input is **normalised** so that a commit
which only reformats, re-comments or re-whitespaces a file does **not** change
the key -- only a change to what the base chain actually deploys does. A trailing
newline appended to `env/sources.lock.json`, a comment added to a reconciler
module, or a reindent of the lido 0140 TypeScript all leave the key untouched.

Included, with the normalisation applied to each:

- **Snapshot format version** (`snapfmt <n>`, `SNAPSHOT_FORMAT_VERSION` in
  `base-key.py`) -- part of the key so a snapshot written in an older on-disk
  format is never restored by a newer `fixturenet-new`. The move from the
  whole-chain (v1) to the execution-layer-only (v2) snapshot bumped it, so the v1
  snapshot's key no longer matches and a v2 base is rebuilt from scratch.
- **Image IDs** (`docker image inspect`): the chain images `ethereum/client-go`,
  `sigp/lighthouse`, `ethpandaops/ethereum-genesis-generator` (read from the
  fixturenet compose); the `toolchain` env-image stage; **one `src-<name>` stage
  per `sources[]` entry** -- its image ID encodes that source's pin *and* its
  build output, so the `sources[]` pins need no separate line; and the `circuits`
  stage. **Not** the whole env image and **not** the `contracts` stage:
  `armada_nitro`'s own contracts are not part of the base chain, so recompiling
  them must not invalidate the base snapshot.
- `env/reconciler/**/*.py` -- hash of each file's **AST with docstrings
  stripped**, so comments, formatting and docstrings do not count.
- **Canonical JSON** (sorted keys, no whitespace): `env/targets/fixturenet-base.json`
  (the base target); `env/lido/steps-fixturenet.json` (the lido step list); and
  `env/sources.lock.json`'s non-`sources` entries (`weth9`, `armada-circuits` --
  the `sources[]` pins being already covered by the stage image IDs).
- **Parsed then canonical JSON**: `env/lido/deploy-params-fixturenet.toml`
  (`tomllib`); the two YAML compose files
  `stack/compose/docker-compose-armada-fixturenet.yml` (the chain: image tags
  **and** the genesis parameters -- chain id, fork epochs, mnemonic, validator
  count) and `stack/compose-jobs/docker-compose-armada-env-reconcile.yml` (the job).
- **Prettier-normalised text** (the repo's own `node_modules` prettier, which the
  helper insists on): `env/lido/0140-plug-staking-modules-via-vote.ts`, the custom
  step lido runs during the deploy.
- Any other (unknown-type) file inside an included directory is hashed by **raw
  bytes** as a fail-safe, so a newly added input is never silently ignored.

Excluded (present but not part of the base chain's state): `env/targets/fixturenet.json`
(the full target -- it adds `armada_nitro` + `funding`); `env/lido/tools/**` (capture/dev
tooling, not run by the deploy); and `env/lido/reference-staking-modules.json` (read by
`verify()` only). The `.key` file written next to each snapshot lists the exact input
lines, so a key is fully auditable; its header documents these rules.

**Where.** `~/deployments/.snapshots/armada-fixturenet-base-<key>.tar.zst` plus
its `.key` file. We keep exactly one base snapshot: writing a new one deletes
every other `armada-fixturenet-base-*` snapshot and key file.

**The two commands** (`stack/scripts/`):

```sh
# Bring up ~/deployments/<name>, restoring the cached base if the key matches,
# else building + snapshotting it first. Prints the warm/cold decision and
# per-phase timings. Mounts the capped RAM disk over data/ itself (see "Chain
# data lives in RAM, capped"); refuses if data/ on disk holds any file. On an
# existing deployment dir it skips init/create and resumes.
stack/scripts/fixturenet-new <name>

# Snapshot a deployment that reconciled ONLY the base target (its manifest must
# name exactly the six base modules). Halts block production (stops the consensus
# layer), records geth's head block, stops geth, tars+zstd the execution layer
# only (geth data + armada_env + EL genesis + the head block), writes the key
# file, prunes other snapshots, and restarts the chain. fixturenet-new's cold path
# calls this for you.
stack/scripts/fixturenet-base-snapshot <deployment-dir>

# Bring ~/deployments/<name> back after its chain is gone (e.g. a host reboot).
# Refuses while data/ is a RAM disk that holds the chain's EL genesis (a live
# chain). Stops the deployment, then runs fixturenet-new (warm path when the
# cached base matches).
stack/scripts/fixturenet-recover <name>
```

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
