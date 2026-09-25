# E3a Reconciler framework, weth module, `reconcile` job

Depends on: E1, E2 (merged). Read `docs/ENVIRONMENT.md` §4–§6 and §8, `stack/README.md` ("Fixturenet"), and
`stack/stacks/armada-nitro-fixturenet/stack.yml`.

## Goal
The reconciler framework and its first module, run as a laconic-so job against the fixturenet. This sets the pattern
that E3b–E6 add modules to.

## Deliver
- `env/reconciler/` (Python 3 standard library only; chain access through `cast` and `forge` subprocesses):
  - `__main__.py`: `python3 -m reconciler --target <file> --rpc <url> --state <dir> [--only <module>] [--verify-only]`.
    - Loads the target; loads `<state>/manifest.json` if present.
    - Runs the modules the target lists, in the order of §4. For each: `observe`, `apply` (skipped with
      `--verify-only`), `verify`.
    - Writes the manifest atomically (temp file, then rename). Keys are sorted, so an unchanged state gives a
      byte-identical file.
    - Prints one line per module: `module, action (adopted|present|deployed|configured), gasUsed`.
  - A module is one file in `env/reconciler/modules/` exposing `observe`, `apply`, `verify`. The framework discovers
    modules by the names in §4; a target naming an unknown module is an error.
  - The deployer key comes from `--key-file` or the env var `DEPLOYER_KEY_FILE`, never from the target file. On the
    fixturenet it is anvil account 0.
  - A failed `verify` exits non-zero, naming the module and the postcondition.
- `env/targets/fixturenet.json`:
  - a `network` block (`name`, `chainId` 31337, `rpcUrl` `http://armada-fixturenet-geth:8545`, `hostRpcUrl`
    `http://127.0.0.1:8545`);
  - `"weth": {"deploy": {}}`.
- Module **weth**:
  - Deploy WETH9 by sending creation code that returns `sources.lock.json` `weth9.runtime` (WETH9 has no constructor
    and no immutables, so the runtime is exact).
  - Verify per §6: `extcodehash` = `weth9.codeHash`; `deposit` 1 ETH then `withdraw` round-trips (the ETH balance
    change equals gas cost only).
- `stack/compose-jobs/docker-compose-armada-env-reconcile.yml`:
  - job `armada-env-reconcile`, image `cerc/armada-nitro-env:local`;
  - runs the reconciler with `--state /env`, where `/env` is named volume `armada_env`;
  - declare `armada_env` in the fixturenet pod's compose file so that laconic-so records it in the deployment spec;
  - the job reaches geth at `http://armada-fixturenet-geth:8545`.
- Add the job to `stacks/armada-nitro-fixturenet/stack.yml` (`jobs:`). Add the run command to `stack/README.md`.

## Acceptance (paste output)
Use a fresh deployment at `~/deployments/armada-fixturenet-e3a`. The E1 deployment `~/deployments/armada-fixturenet-e1`
holds host port 8545; stop it first with `laconic-so deployment --dir ~/deployments/armada-fixturenet-e1 stop` (do not
delete it).
```sh
~/bin/laconic-so deployment --dir <dep> run-job armada-env-reconcile      # weth: deployed; verify OK; gas
N0=$(cast nonce 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url http://127.0.0.1:8545)
~/bin/laconic-so deployment --dir <dep> run-job armada-env-reconcile      # weth: present; no transactions
cast nonce 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url http://127.0.0.1:8545   # equals N0
cast keccak $(cast code <weth> --rpc-url http://127.0.0.1:8545)                         # equals sources.lock.json weth9.codeHash
```
- Also show the manifest is byte-identical across the two runs (`sha256sum` before and after the second run).
- Negative cases, in a scratch copy of the state:
  - (a) point `weth` in the manifest at an address without code: `--verify-only` fails naming the postcondition, and
    a normal run refuses to redeploy over it;
  - (b) a target naming module `nosuch`: the run fails naming it.

## Out of scope
The usdc, cctp and later modules (E3b onward). Any edit to upstream repositories.
