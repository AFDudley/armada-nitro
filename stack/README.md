# Laconic-so Stacks

This directory contains the stack definitions used by the laconic-so orchestrator.

## Fixturenet

A single-node Proof-of-Stake devnet on upstream geth + lighthouse with every fork through
Osaka active at genesis.

### Commands

```sh
# 1. Generate the deployment spec (maps geth's 8545/8546 and the beacon's 5052 to
#    127.0.0.1 on the host)
laconic-so --stack stack/stacks/armada-nitro-fixturenet deploy init \
  --map-ports-to-host localhost-same \
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
- `armada-fixturenet-validator` - lighthouse validator client (64 validators)

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

### Environment reconciler

`armada-env-reconcile` brings the fixturenet to the target state described by
`env/targets/fixturenet.json` (docs/ENVIRONMENT.md §3-§6) and writes a
manifest to the `armada_env` named volume, bind-mounted to
`<deployment>/data/armada_env` (it is declared in the fixturenet pod's
compose file so `deploy create` records it, per `docker-compose-armada-fixturenet.yml`).
The job sees it at `/env`.

It needs the deployer key in a file under that same volume -- key files
belong in the reconciler's state directory, never in the repository or on
the target. Put it there once per deployment before the first run (on the
fixturenet this is anvil account 0):

```sh
# The volume's real name is the compose project prefix + armada_env, e.g.:
VOLUME=$(docker volume ls -q | grep armada_env)
docker run --rm -v ${VOLUME}:/env alpine \
  sh -c "printf '%s' 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 > /env/deployer.key"

laconic-so deployment --dir <deployment> run-job armada-env-reconcile
```

A second run sends no transactions and rewrites a byte-identical manifest
(`<deployment>/data/armada_env/manifest.json`). Setting `RECONCILER_VERIFY_ONLY=1`
in the environment before `run-job` checks postconditions read-only, without
deploying anything; `RECONCILER_ONLY=<module>` restricts the run to one module.
