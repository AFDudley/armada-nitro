# armada-nitro test environment — specification

## 1. Purpose

One target state, reached by code on two networks:

1. a laconic-so **fixturenet** (real geth + lighthouse, every fork through Osaka active at genesis);
2. **Sepolia**, brought to parity with the mainnet shape the contracts will meet.

The target state is: WETH9, Circle's FiatToken USDC, Circle's CCTP v2, Aave v3 with a USDC reserve and its StataToken
wrapper (`waUSDC`), Lido core (stETH/wstETH; oracle code deployed, **unconfigured**), Armada's PrivacyPool with the
`demo3` verification keys and real proof verification, and armada-nitro's contracts.

A **reconciler** brings a network to the target and writes a **deployment manifest**. Two gate jobs run against the
manifest. armada-client consumes the same manifest (its P1-05); it builds no environment of its own.

Order: everything is proven on the fixturenet before anything is sent to Sepolia.

The existing anvil stack (`stack/stacks/armada-nitro`, pool in testing mode) stays as the contract-level inner loop.
It is not a gate.

## 2. Fixed choices

| Choice | Value | Why |
|---|---|---|
| Fixturenet chain id | `31337` | armada-poc's hardhat `hub` network pins `chainId: 31337` (`hardhat.config.ts`); Armada's deploy and e2e scripts then run unmodified |
| Fixturenet premine | accounts 0–9 of the public anvil/hardhat mnemonic (`test test … junk`), 10,000 ETH each. Block fees go to `0x000000000000000000000000000000000000fEE5`, outside the funded set, so test-account balances move only by their own transactions | armada-poc's `hub` network and armada-nitro's scripts derive signers from it |
| Execution client | `ethereum/client-go:v1.17.6` (upstream release, 2026-09-23) | replaces the stale `cerc-io/go-ethereum@v1.11.6-statediff-v5` |
| Consensus client | `sigp/lighthouse:v8.2.2` (2026-08-18) | replaces `sigp/lighthouse:v5.1.2` |
| Genesis | `ethpandaops/ethereum-genesis-generator:6.2.1`, all forks through Fulu/Osaka at epoch 0 | armada-nitro compiles with `evm_version = "osaka"` (`foundry.toml:11`) |
| USDC | `circlefin/stablecoin-evm` `release-2026-08-12T202509` (FiatToken proxy + current implementation) | same token as mainnet and Sepolia |
| CCTP | `circlefin/evm-cctp-contracts` `release-2025-10-01T154348`, v2 contracts | Armada's `PrivacyPool.initialize` takes a TokenMessenger and MessageTransmitter; demo3 uses Circle's real CCTP v2 |
| Aave | `aave-dao/aave-v3-origin` `v3.7.0`: `scripts/DeployAaveV3MarketBatched.sol`, `AaveV3ConfigEngine.listAssets`, `StataTokenFactory` | the StataToken wrapper is the `waEthUSDC` shape on mainnet |
| Aave USDC price source | fixturenet: `MockAggregator` (`src/contracts/mocks/oracle/CLAggregators/`) fixed at `1e8`; Sepolia: Chainlink USDC/USD | listing needs a feed; borrowing is out of scope |
| Lido | `lidofinance/core` `v4.0.1`, scratch deploy (`scripts/dao-deploy.sh`, steps in `scripts/scratch/steps/`) | oracle contracts deployed; no committee members, no reports |
| Armada | `ship-armada/armada-poc` `532bc064` (= `lib/armada-poc`, the demo3 commit), `scripts/deploy_privacy_pool.ts` with `CCTP_MODE=real` | same code and verification keys as demo3 |
| armada-nitro | this repository, `script/Deploy.s.sol` | |
| Toolchain | Foundry v1.8.3 with `FOUNDRY_DYNAMIC_TEST_LINKING=false` (image-wide: its generated helpers do not compile under the solc 0.6/0.7 that stablecoin-evm and CCTP pin), Node 22 with yarn 4.9.2 (Lido `engines.node >=22`; stablecoin-evm uses its own yarn 1 via `packageManager`), Python 3 | |

## 3. Layout

```
env/
  sources.lock.json        every upstream source: repo, ref, resolved commit; WETH9 reference code hash + provenance
  targets/fixturenet.json  desired state for the fixturenet (deploy parameters per module)
  targets/sepolia.json     desired state for Sepolia (adopt existing addresses, deploy the gaps)
  reconciler/              Python 3 package, run as `python3 -m reconciler`
    modules/               weth.py usdc.py cctp.py aave.py lido.py armada.py armada_nitro.py funding.py
  aave/                    Aave market input for this environment (Solidity)
  gates/                   verify.py (read-only postconditions), nitro-e2e (real-proof channel scenario)
  manifests/sepolia.json   committed Sepolia manifest (addresses only, no keys)
stack/
  container-build/cerc-armada-nitro-env/   image: toolchain + every source at its pin
  compose/docker-compose-armada-fixturenet.yml
  compose-jobs/docker-compose-armada-env-{reconcile,verify,nitro-e2e}.yml
  stacks/armada-nitro-fixturenet/stack.yml
```

## 4. Reconciler contract

`python3 -m reconciler --target env/targets/<network>.json --rpc <url> --state <dir>` writes
`<dir>/manifest.json` and, on the fixturenet only, `<dir>/keys/<address>.key`.

- **Modules run in dependency order**: weth, usdc, cctp, aave, lido, armada, armada_nitro, funding.
- **Each module has three steps.**
  - `observe`: read the manifest and the chain.
  - `apply`: deploy or configure only what is missing.
  - `verify`: assert its postconditions (§6) against the chain.
- **A module target is either `deploy` (with parameters) or `adopt` (with addresses).**
  - An adopted address is verified and never redeployed.
  - An adopted address that fails `verify` is an error. The reconciler never replaces it.
- **Idempotent.** A second run on a reconciled network sends no transactions (every account nonce is unchanged), and it
  rewrites an identical manifest.
- **Gas.** The reconciler prints gas used per module. The fixturenet numbers size the Sepolia deployer's funding.
- **Upstream sources run from their pinned checkouts inside the image.**
  - Upstream repositories are used as published.
  - Where a deploy needs inputs, the environment supplies them from its own files (`env/aave/…`, target parameters,
    environment variables).
  - An upstream script that cannot be driven without editing it is a stop-and-report.

## 5. Manifest schema

armada-client's P1-05 reads the first five keys and nothing else. Change them only together with that brief.

```json
{
  "network":      { "name": "fixturenet", "chainId": 31337, "rpcUrl": "http://armada-fixturenet-geth:8545", "hostRpcUrl": "http://127.0.0.1:8545" },
  "armada":       { "pool": "0x…", "usdc": "0x…", "deployBlock": 0, "artifactsBaseUrl": "https://circuits.knowable.run/v0.1.0-dev" },
  "armadaNitro":  { "adjudicator": "0x…", "consensusApp": "0x…", "hubCustodian": "0x…" },
  "assets":       { "weth": "0x…", "wstETH": "0x…", "waUSDC": "0x…" },
  "testAccounts": [ { "address": "0x…", "privateKeyFile": "keys/0x….key" } ],
  "usdc":  { "proxy": "0x…", "implementation": "0x…", "masterMinter": "0x…" },
  "cctp":  { "tokenMessenger": "0x…", "messageTransmitter": "0x…", "tokenMinter": "0x…", "domain": 0 },
  "aave":  { "poolAddressesProvider": "0x…", "pool": "0x…", "aUSDC": "0x…", "stataTokenFactory": "0x…", "usdcPriceFeed": "0x…" },
  "lido":  { "locator": "0x…", "stETH": "0x…", "wstETH": "0x…", "accountingOracle": "0x…", "hashConsensus": ["0x…"] },
  "sources": { "<name>": "<commit>" },
  "gasUsed": { "<module>": 0 }
}
```

## 6. Postconditions (the oracles)

Every expected value comes from outside the code under test: mainnet, Sepolia, an upstream specification, or a
recorded constant with provenance.

| Module | Postcondition |
|---|---|
| weth | `extcodehash` equals mainnet WETH9's (`0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`), recorded in `sources.lock.json` with the command and block. `deposit` 1 ETH then `withdraw` round-trips |
| usdc | `name()`/`symbol()`/`decimals()` = `USDC`/`USDC`/`6`. `version()` equals Sepolia USDC's. `masterMinter()` = the target's. A minter configured by `masterMinter` can `mint`. Transfer works. The implementation's runtime equals mainnet USDC's implementation byte for byte after stripping the metadata trailer and zeroing library link slots (E3b) |
| cctp | `messageTransmitter.localDomain()` = target domain. `tokenMessenger.localMessageTransmitter()` = transmitter. The TokenMinter lists USDC as a local token. `messageTransmitter.version()` equals the Sepolia v2 transmitter's |
| aave | `getReserveData(usdc).aTokenAddress` ≠ 0. LTV, liquidation threshold, liquidation bonus, reserve factor and decimals equal mainnet's USDC reserve (read with `cast` from mainnet at a recorded block). `stata.asset()` = USDC. Depositing 100 USDC into the stata token and redeeming every share returns 100 USDC at index 1 |
| lido | `wstETH.stETH()` = stETH. `submit` 1 ETH mints stETH. `wstETH.stEthPerToken()` = `1e18` (no oracle report ever). Every HashConsensus has zero members |
| armada | `testingMode()` = false. For each of the 19 `(nullifiers, commitments)` shapes, `getVerificationKey` equals the value from the demo3 pool on Sepolia (`0x5f3324b47b3CFf937BB67C30B362898E193e5216`), read by `cast`. The pool's USDC and CCTP addresses equal the manifest's |
| armada_nitro | `adjudicator.pool()` = Armada pool. The custodian's group key = the target's. The revocation delay = the target's |
| funding | each test account holds ≥ 1,000 USDC and ≥ 100 ETH |

## 7. Gates

- **`armada-env-verify`:**
  - runs every §6 postcondition read-only against a manifest;
  - then runs Armada's own `scripts/capture/e2e-armada-circuits.ts` (shield, private transfer, unshield; real Groth16
    proofs from Armada's WASM/zkey, verified on chain) against the network.
- **`armada-nitro-e2e`:** the channel scenario of `script/LocalScenario.s.sol`, with channel funding by real-proof
  `depositFromNote`:
  - an unshield of an ERC20 note to the adjudicator (`npk` = the adjudicator address);
  - `adaptContract` = the adjudicator;
  - `adaptParams` = `depositBinding(channelId, expectedHeld)`.

  It then runs a cooperative close and a force close through a real challenge window. It verifies payouts from chain
  state and from the pool's `Shield` logs.

Done = on the fixturenet, reconcile (twice, the second sending nothing), then both gates green. For Sepolia: the same,
after the fixturenet is green.

## 8. Worker protocol (localfirst)

1. Work on kelce in `~/code/git_puller/repos/armada-nitro`, on branch `task/<id>` from `main`. `export PATH=$HOME/.foundry/bin:$PATH`.
   laconic-so is `~/bin/laconic-so`.
2. Do only what the brief says. If a fact in the brief is wrong (a path, a signature, a version, a script's
   behavior), stop and report the discrepancy with evidence instead of improvising.
3. Run the brief's acceptance commands exactly and include their real output in the report.
4. Tests and checks must be seen failing for the right reason before they pass. Each brief names a negative case.
   There are no exception lists, no skipped checks, and no retries to green.
5. Commit with a message naming the task id. Do not push; the integrator reviews and merges.
6. Report: files changed, acceptance output, gas per module where relevant, open questions.

## 9. Tasks

| Task | Title | Depends on |
|---|---|---|
| E1 | Fixturenet pod: upstream geth + lighthouse, Osaka at genesis | — |
| E2 | Environment image and `sources.lock.json` | — |
| E3a | Reconciler framework, weth module, `reconcile` job | E1, E2 |
| E3b | usdc and cctp modules (USDC bytecode oracle against mainnet) | E3a |
| E4 | Aave module | E3b |
| E5 | Lido module | E3a |
| E6 | Armada, armada_nitro, funding modules; manifest complete | E3b (armada needs usdc + cctp) |
| E7 | Gates: `armada-env-verify`, `armada-nitro-e2e` | E4, E5, E6 |
| E8 | Sepolia target (deferred) | E7 green on the fixturenet; a funded Sepolia deployer key |
| E9 | Circuits baked into the image; deployer key from laconic-so deployment config | E7 |
| E10 | Gate fixes: our own pool e2e (shield/transfer/unshield); challenge window enforced | E9 |
| E11 | Aave and Lido end to end through channels (`waUSDC`, wstETH, real yield) | E10, E12 |
| E12 | Lido: run the skipped scratch steps (0135/0140/0150) without impersonation | E9 |
| E13 | Exercise adopt mode on the fixturenet | E12 |
| E14 | Hub custodian with real 2-of-3 FROST signing | E10 |
| E15 | Challenge response (watchtower behavior) | E10 |

E1 and E2 run in parallel. So do E4, E5 and E6. E9–E15 run serially: E9, E10, E12, E11, E13, E14, E15.
