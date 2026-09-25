# E3b usdc and cctp modules

Depends on: E3a (merged). Read `docs/ENVIRONMENT.md` §4–§6 and §8, and the reconciler framework in `env/reconciler/`.

## Goal
Circle's FiatToken USDC and CCTP v2, deployed from their pinned upstream sources. USDC's implementation is proven to be
mainnet's code, byte for byte.

## Deliver
- Module **usdc**:
  - Deploy with `stablecoin-evm`'s `scripts/deploy/deploy-fiat-token.s.sol`, driven by the environment variables that
    script reads (`TOKEN_NAME` `USDC`, `TOKEN_SYMBOL` `USDC`, `TOKEN_CURRENCY` `USD`, `TOKEN_DECIMALS` 6; owner,
    masterMinter owner, pauser, blacklister = target parameters, anvil account 0 on the fixturenet; `PROXY_ADMIN_ADDRESS`
    = anvil account 9, which must differ from every other role because FiatToken's proxy rejects non-admin calls from its
    admin). The script sets lostAndFound to the owner (`initializeV2_1(owner)`); it is not a parameter.
  - It runs inside `cerc/armada-nitro-env`, which sets `FOUNDRY_DYNAMIC_TEST_LINKING=false`. With the Foundry 1.8.3
    default (`true`) the solc 0.6.12 build fails in generated `foundry-pp/` helpers.
  - Record `usdc.proxy`, `usdc.implementation`, `usdc.masterMinter`.
  - Verify per §6, plus the **bytecode oracle** below.
    - Read `version()` from Sepolia USDC `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` with `cast` at run time.
    - Negative case: a mint from an unconfigured minter reverts.
- **USDC bytecode oracle** (in the usdc module's `verify`):
  - Implementation address: read the proxy's implementation slot
    `0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3` (`cast storage`) on the fixturenet, and on
    mainnet for USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` (`https://ethereum-rpc.publicnode.com`).
  - Normalize both runtimes the same way:
    1. strip the Solidity metadata trailer (the last two bytes give its CBOR length `n`; drop the last `n + 2` bytes);
    2. zero the library link slots listed in the build artifact's `deployedBytecode.linkReferences` (for
       `FiatTokenV2_2` today: `SignatureChecker` at offsets 18391 and 20106, 20 bytes each). Read the offsets from the
       artifact; do not hard-code them.
  - The normalized fixturenet runtime must equal mainnet's. Print both lengths and the count of differing bytes (0).
  - Measured by the integrator on the pinned source: normalized length 23,411 bytes; the pinned build, mainnet
    (`0x43506849D7C04F9138D1A2050bbF3A0c054402dd`) and Sepolia (`0xDa317C1d3E835dD5F1BE459006471aCAA1289068`) are
    identical.
- Module **cctp**:
  - Deploy CCTP v2 from `evm-cctp-contracts` `scripts/v2/` (`DeployImplementationsV2.s.sol`, `DeployProxiesV2.s.sol`,
    and whatever CREATE2 factory `PredictCreate2Deployments`/the scripts require).
    - Local domain 0; one attester = anvil account 8; USDC (from the usdc module) registered as a local token on the
      TokenMinter; mint allowance configured by the usdc module's masterMinter.
  - Record `tokenMessenger`, `messageTransmitter`, `tokenMinter`, `domain`.
  - Verify per §6. Read the Sepolia v2 transmitter's `version()` from the address demo3 used (armada-poc
    `deployments/privacy-pool-hub-sepolia.json`, key `cctp.messageTransmitter`, currently
    `0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275`, version 1, domain 0).
- Add `usdc` and `cctp` to `env/targets/fixturenet.json`.

## Acceptance (paste output)
On a fresh fixturenet deployment:
```sh
~/bin/laconic-so deployment --dir <dep> run-job armada-env-reconcile      # weth, usdc, cctp: deployed; verify OK; gas per module
N0=$(cast nonce 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url http://127.0.0.1:8545)
~/bin/laconic-so deployment --dir <dep> run-job armada-env-reconcile      # all "present"; no transactions
cast nonce 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url http://127.0.0.1:8545   # equals N0
```
- Paste the bytecode oracle's output: lengths and differing-byte count against mainnet.
- Negative cases, each seen failing:
  - (a) oracle discrimination: deploy a FiatTokenV2_2 built with a different optimizer setting (`forge build
    --optimizer-runs 200` in a scratch copy of `/src/stablecoin-evm` inside the image) and run the oracle against it;
    it must report differing bytes;
  - (b) point the manifest's `usdc.proxy` at the WETH address in a scratch copy of the state: `--verify-only` fails
    on usdc naming the postcondition, and a normal run refuses to redeploy over it.
- Paste the manifest's `usdc` and `cctp` sections.

## Out of scope
Aave, Lido, Armada, armada-nitro, funding (E4–E6). Any edit to upstream repositories.
