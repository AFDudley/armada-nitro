# E1 Fixturenet pod: upstream geth + lighthouse, Osaka at genesis

Depends on: nothing. Read `docs/ENVIRONMENT.md` §2–§3 and §8.

## Goal
A laconic-so pod running a single-node proof-of-stake devnet on current upstream clients with every fork through
Fulu/Osaka active from genesis. The pod does not reuse stack-orchestrator's `fixturenet-eth` images, which build the
stale `cerc-io/go-ethereum@v1.11.6-statediff-v5` and `sigp/lighthouse:v5.1.2`.

## Read first
- kelce `~/src/stack-orchestrator/stack_orchestrator/data/compose/docker-compose-fixturenet-eth.yml` and
  `container-build/cerc-fixturenet-eth-{genesis,geth,lighthouse}/`: the shape to follow (genesis container, EL, CL
  beacon node, validator client, a shared genesis volume).
- `ethpandaops/ethereum-genesis-generator` at tag `6.2.1`: its README and `defaults/` (the env file listing
  `CHAIN_ID`, `EL_AND_CL_MNEMONIC`, `*_FORK_EPOCH`, `SLOT_DURATION_IN_SECONDS`, `NUMBER_OF_VALIDATORS`, premine
  settings). Use the names as they appear in that tag.

## Deliver (under `stack/`)
- `compose/docker-compose-armada-fixturenet.yml` with these services:
  - `armada-fixturenet-genesis`: image `ethpandaops/ethereum-genesis-generator:6.2.1`.
    - Generates EL and CL genesis into a named volume `armada_fixturenet_genesis`. Idempotent: skips if genesis exists.
    - `CHAIN_ID=31337`; every fork epoch (Altair … Electra, Fulu) = 0; slot time 2 s; 64 validators from a fixed
      validator mnemonic.
    - Premine: accounts 0–9 of mnemonic `test test test test test test test test test test test junk` (path
      `m/44'/60'/0'/0/i`), 10,000 ETH each.
    - The deposit contract is placed where the generator places it. Record the address.
  - `armada-fixturenet-geth`: image `ethereum/client-go:v1.17.6`.
    - Inits from the generated `genesis.json`. HTTP and WS RPC on 8545/8546 with `eth,net,web3,debug,txpool`.
    - Authenticated engine API on 8551 with a JWT secret generated into the genesis volume.
    - Ports 8545 and 8546 published so that the deployment spec from `deploy init --map-ports-to-host
      localhost-same` puts them on the host's `127.0.0.1:8545`.
  - `armada-fixturenet-beacon`: image `sigp/lighthouse:v8.2.2`, `lighthouse bn` against geth's engine API, testnet
    dir from the genesis volume, no peers needed.
  - `armada-fixturenet-validator`: image `sigp/lighthouse:v8.2.2`, `lighthouse vc` with the 64 generated validator
    keys.
  - Healthcheck on geth: `eth_blockNumber` > 0.
- `stacks/armada-nitro-fixturenet/stack.yml`: pod `armada-fixturenet` (later tasks add jobs).
- `stack/README.md` section "Fixturenet": the exact build/init/create/start commands.

## Acceptance (paste output)
With a deployment created from `stacks/armada-nitro-fixturenet` and started, from the kelce host:
```sh
cast chain-id --rpc-url http://127.0.0.1:8545                       # 31337
cast balance 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --rpc-url http://127.0.0.1:8545   # 10000 ether (account 1)
sleep 30; cast block-number --rpc-url http://127.0.0.1:8545         # advancing
cast rpc eth_config --rpc-url http://127.0.0.1:8545                 # current fork shows Osaka
curl -s localhost:<beacon http port>/eth/v1/beacon/states/head/finality_checkpoints   # finalized epoch > 0 after ~3 epochs
```
Prove Osaka is active by behavior, not only by config:
- deploy and call a contract that uses `CLZ` (EIP-7939, Osaka): for example, runtime `0x6001` `1e` … returning
  `clz(1)` = 255;
- negative case: the same call against an anvil started with `--hardfork prague` must fail;
- paste both results.

Then stop the deployment, start it again, and paste `cast block-number` to show that the chain resumed: genesis is not
regenerated.

## Out of scope
Contracts, the reconciler, multiple nodes, statediff, ipld-eth-db.
