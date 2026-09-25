# E6 Armada, armada_nitro, funding modules; manifest complete

Depends on: E3b (usdc, cctp). Read `docs/ENVIRONMENT.md` §4–§6, §8, and in `/src/armada-poc` (commit `532bc064`):
`scripts/deploy_privacy_pool.ts`, `config/networks.ts` (`CCTP_MODE`, `HUB_USDC`, `CCTP_TOKEN_MESSENGER`,
`CCTP_MESSAGE_TRANSMITTER`, `CCTP_TOKEN_MINTER`, `HUB_CCTP_DOMAIN`, `DEPLOY_ENV`, `TREASURY_ADDRESS`),
`hardhat.config.ts` (network `hub`: chain id 31337, anvil mnemonic), `lib/artifacts.ts` (`loadVerificationKeys`,
`TESTING_ARTIFACT_CONFIGS`), `deployments/privacy-pool-hub-sepolia.json`. In this repo: `script/Deploy.s.sol`.

## Goal
Armada's pool deployed by Armada's own script at the demo3 commit, over the environment's Circle USDC and CCTP v2,
with the same verification keys as demo3 and real verification. Then armada-nitro over that pool. Then funded test
accounts. The manifest is complete (§5).

## Deliver
- `env/reconciler/modules/armada.py`:
  - Runs `npx hardhat run scripts/deploy_privacy_pool.ts --network hub` in `/src/armada-poc`.
    - Environment: `HUB_RPC` = the target RPC, `DEPLOY_ENV=local`, `CCTP_MODE=real`, `HUB_USDC`,
      `CCTP_TOKEN_MESSENGER`, `CCTP_MESSAGE_TRANSMITTER`, `CCTP_TOKEN_MINTER`, `HUB_CCTP_DOMAIN` from the manifest;
      `TREASURY_ADDRESS` = anvil account 7.
    - Only the hub deploy: no clients, no governance, no crowdfund.
    - Read the addresses from the deployment file the script writes.
  - Record `armada.pool`, `armada.usdc`, `armada.deployBlock` (from the file), and
    `armada.artifactsBaseUrl` = `https://circuits.knowable.run/v0.1.0-dev`.
  - Verify per §6:
    - For each of the 19 shapes in `TESTING_ARTIFACT_CONFIGS`, compare `getVerificationKey(nullifiers, commitments)`
      on the fixturenet pool with the same call on the Sepolia demo3 pool `0x5f3324b47b3CFf937BB67C30B362898E193e5216`
      (`cast call`, public Sepolia RPC).
    - If the pool does not expose `getVerificationKey`, stop and report.
- `env/reconciler/modules/armada_nitro.py`:
  - Runs `forge script script/Deploy.s.sol --broadcast` in `/src/armada-nitro`.
    - `ARMADA_POOL` = the pool; `HUB_REVOCATION_DELAY` from the target (fixturenet 60).
    - Group key from the target: on the fixturenet, derived as in `stack/container-build/cerc-armada-nitro-foundry/armada-nitro-local`
      from scalar `0xa4ddf31f7f32ba696f14ce50ecf3f21e3e100e83bdf47966e7b07468e9500b6e`.
  - Record `armadaNitro.{adjudicator, consensusApp, hubCustodian}`. Verify per §6.
- `env/reconciler/modules/funding.py` (targets with `testAccounts` only):
  - Anvil accounts 1–4.
  - Configure a minter from the usdc module's `masterMinter` and mint 1,000 USDC to each.
  - Write `<state>/keys/<address>.key` (mode 0600).
  - Record `testAccounts`.
  - Idempotent: mint only the shortfall to 1,000 USDC.

## Acceptance (paste output)
```sh
~/bin/laconic-so deployment --dir <dep> run-job armada-env-reconcile     # armada, armada_nitro, funding: deployed; verify OK; gas
~/bin/laconic-so deployment --dir <dep> run-job armada-env-reconcile     # all present; nonces of accounts 0 and 8 unchanged
cat <dep>/data/armada_env/manifest.json   # (or wherever laconic-so places the volume: report the path)
cast call <pool> "testingMode()(bool)" --rpc-url http://127.0.0.1:8545     # false
cast call <adjudicator> "pool()(address)" --rpc-url http://127.0.0.1:8545  # = pool
```
- Paste the 19-shape verification-key comparison: shape, a hash of each side, equal or not.
- Negative case: compare the fixturenet VK for shape (1,2) against Sepolia's shape (2,2); the check must report a
  mismatch.
- Paste the per-module gas table.

## As built (findings from the run)
- `deploy_privacy_pool.ts` reads CCTP addresses from `deployments/hub-v3.json`, written by
  `scripts/deploy_cctp_sepolia.ts` (generic despite the name; with `CCTP_MODE=real` it records and checks the given
  addresses, sending no transactions). The module runs it first with the same environment.
- Loading verification keys needs Armada's circuit build (`scripts/fetch-circuits.sh`, which uses `gh`). The image has
  no `gh`, so the module downloads the same release asset (`ship-armada/armada-circuits` `v0.1.0-dev`, tarball
  SHA-256 `e7c4e5ea…369a`, pins copied from `fetch-circuits.sh`) over HTTPS and checks it.
- `script/Deploy.s.sol` writes `deployments/<chainId>.json` but does not create `deployments/`; the module creates it.
- Fixturenet gas: weth 727,366; usdc 8,008,767; cctp 12,478,907; armada 33,711,821; armada_nitro 6,588,924; funding
  273,312; total 61,789,097.

## Out of scope
Proof generation, the gates (E7), Armada clients/governance, any edit to armada-poc.
