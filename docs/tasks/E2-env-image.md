# E2 Environment image and `sources.lock.json`

Depends on: nothing. Read `docs/ENVIRONMENT.md` §2–§3 and §8.

## Goal
One image, `cerc/armada-nitro-env:local`, holding the toolchain and every upstream source at its pin, with
dependencies installed, so reconciler modules and gates run offline from the network's point of view (no clone or
install at job time).

## Deliver
- `env/sources.lock.json`: an array of `{name, repo, ref, commit}`.
  - Each `commit` is resolved with `git ls-remote` (or, for `armada-poc`, `git -C lib/armada-poc rev-parse HEAD`).
  - Entries:
    - `stablecoin-evm` `circlefin/stablecoin-evm` `release-2026-08-12T202509`;
    - `evm-cctp-contracts` `circlefin/evm-cctp-contracts` `release-2025-10-01T154348`;
    - `aave-v3-origin` `aave-dao/aave-v3-origin` `v3.7.0`;
    - `lido-core` `lidofinance/core` `v4.0.1`;
    - `armada-poc` `ship-armada/armada-poc` `532bc0641443879e30c07b98970f6e11d5d9400c`.
  - Plus a `weth9` object: `{mainnetAddress: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", codeHash, runtime,
    provenance}`.
    - `codeHash` = `cast keccak $(cast code 0xC02a… --rpc-url https://ethereum-rpc.publicnode.com)`.
    - `runtime` = that code.
    - `provenance` = the exact commands and the mainnet block number used.
- `stack/container-build/cerc-armada-nitro-env/Dockerfile` and `build.sh`:
  - Base Debian bookworm. Foundry v1.8.3 (`foundryup -i v1.8.3`), Node 22 LTS, corepack-enabled yarn 4.9.2,
    Python 3, `jq`, `git`.
  - Clones each source from `sources.lock.json` at its `commit` into `/src/<name>` (with submodules) and installs
    dependencies as each project documents:
    - `forge build` for Foundry repos;
    - `yarn install --immutable` for `lido-core`;
    - `npm ci` plus `npx hardhat compile` for `armada-poc`.
  - Copies this repository to `/src/armada-nitro` and runs `forge build` there.
  - `build.sh` passes the lock file into the build so that a changed pin rebuilds.
- `stacks/armada-nitro-fixturenet/stack.yml` lists the container (`cerc/armada-nitro-env`).

## Acceptance (paste output)
```sh
~/bin/laconic-so --stack ~/code/git_puller/repos/armada-nitro/stack/stacks/armada-nitro-fixturenet build-containers --include cerc/armada-nitro-env
docker run --rm cerc/armada-nitro-env:local sh -c 'forge --version; node --version; yarn --version; python3 --version;
  for d in /src/*; do printf "%s " $d; git -C $d rev-parse HEAD 2>/dev/null || echo "(no git)"; done'
```
Each printed commit equals `sources.lock.json`. Then show that the image is pinned: change one `commit` in a scratch
copy of the lock to a wrong value; the build must fail at the checkout. Paste that failure, then revert.

## Out of scope
Running any deploy. The fixturenet pod (E1).
