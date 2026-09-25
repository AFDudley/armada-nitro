# E3 Reconciler core; weth, usdc, cctp modules; `reconcile` job

Depends on: E1 (fixturenet), E2 (image). Read `docs/ENVIRONMENT.md` §4–§6 and §8.

## Goal
The reconciler framework and the first three modules, run as a laconic-so job against the fixturenet.

## Deliver
- `env/reconciler/` (Python 3 standard library only; chain access through `cast` and `forge` subprocesses):
  - `__main__.py`: `python3 -m reconciler --target <file> --rpc <url> --state <dir> [--only <module>] [--verify-only]`.
    - Loads the target; loads `<state>/manifest.json` if present.
    - Runs modules in the order of §4; for each one: `observe`, `apply` (skipped with `--verify-only`), `verify`.
    - Writes the manifest atomically: temp file, then rename.
    - Prints `module, action (adopted|present|deployed|configured), gasUsed`.
  - The deployer key comes from `--key-file` or the env var `DEPLOYER_KEY_FILE`, never from the target file. On the
    fixturenet it is anvil account 0.
  - A failed `verify` exits non-zero, naming the module and the postcondition.
- `env/targets/fixturenet.json`: `network` block (`name`, `chainId` 31337, `rpcUrl`, `hostRpcUrl`) and one entry per
  module: `{"deploy": {…}}`.
- Module **weth**:
  - Deploy WETH9 by sending creation code that returns `sources.lock.json` `weth9.runtime` (WETH9 has no constructor
    and no immutables, so the runtime is exact).
  - Verify per §6.
- Module **usdc**:
  - Deploy with `stablecoin-evm`'s `scripts/deploy/deploy-fiat-token.s.sol`, driven by the environment variables that
    script reads (name `USDC`, symbol `USDC`, currency `USD`, decimals 6; owner, masterMinter, pauser, blacklister,
    lostAndFound = target parameters; on the fixturenet all are anvil account 0 except lostAndFound = account 9).
  - Run it inside `cerc/armada-nitro-env`, which sets `FOUNDRY_DYNAMIC_TEST_LINKING=false`; with the Foundry 1.8.3
    default (`true`) the solc 0.6.12 build fails in generated `foundry-pp/` helpers. The same applies to CCTP (solc 0.7.6).
  - Verify per §6.
    - Read `version()` from Sepolia USDC `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` with `cast` at run time.
    - Negative case: a mint from an unconfigured minter reverts.
- Module **cctp**:
  - Deploy CCTP v2 from `evm-cctp-contracts` `scripts/v2/` (`DeployImplementationsV2.s.sol`,
    `DeployProxiesV2.s.sol`, and whatever CREATE2 factory `PredictCreate2Deployments`/the scripts require).
    - Local domain 0; one attester = anvil account 8; USDC (from the usdc module) registered as a local token on the
      TokenMinter; mint allowance configured by the usdc module's masterMinter.
  - Record `tokenMessenger`, `messageTransmitter`, `tokenMinter`, `domain`.
  - Verify per §6; read the Sepolia v2 transmitter's `version()` from the address demo3 used (armada-poc
    `deployments/privacy-pool-hub-sepolia.json`, key `cctp.messageTransmitter`).
- `stack/compose-jobs/docker-compose-armada-env-reconcile.yml`:
  - job `armada-env-reconcile`; image `cerc/armada-nitro-env:local`;
  - runs the reconciler with `--state /env`, where `/env` is named volume `armada_env` (declared by the fixturenet pod
    so that it is recorded in the deployment spec);
  - the pod exports the RPC as `http://armada-fixturenet-geth:8545`.
- Add the job to `stacks/armada-nitro-fixturenet/stack.yml`.

## Acceptance (paste output)
On a fresh fixturenet deployment:
```sh
~/bin/laconic-so deployment --dir <dep> run-job armada-env-reconcile      # weth, usdc, cctp: deployed; verify OK; gas per module
N0=$(cast nonce 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url http://127.0.0.1:8545)
~/bin/laconic-so deployment --dir <dep> run-job armada-env-reconcile      # all "present"; no transactions
cast nonce 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url http://127.0.0.1:8545   # equals N0
cast keccak $(cast code <weth> --rpc-url http://127.0.0.1:8545)                         # equals sources.lock.json weth9.codeHash
```
- Negative case: point the manifest's `usdc.proxy` at the WETH address in a scratch copy of the state. `--verify-only`
  must fail on usdc naming the postcondition, and a normal run must refuse to redeploy over it.
- Paste the manifest's `usdc` and `cctp` sections.

## Out of scope
Aave, Lido, Armada, armada-nitro, funding (E4–E6). Any edit to upstream repositories.
