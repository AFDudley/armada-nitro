# E7 Gates: `armada-env-verify` and `armada-nitro-e2e`

Depends on: E4, E5, E6. Read `docs/ENVIRONMENT.md` §6–§8; `script/LocalScenario.s.sol`; `src/ArmadaNitroAdjudicator.sol`
(`depositBinding`, `depositFromNote` and its `require`s); `test/helpers/ArmadaNotes.sol`; in `/src/armada-poc`:
`scripts/capture/e2e-armada-circuits.ts` and `lib/sdk/` (`init`, `wallet`, `prover`, `shield`, `network`,
`transfer`).

## Goal
The two jobs whose green result on the fixturenet defines "done" for the environment.

## Deliver
- Job `armada-env-verify` (image `cerc/armada-nitro-env:local`):
  1. `python3 -m reconciler --verify-only` against `/env/manifest.json`: every §6 postcondition, read-only.
  2. Armada's own `npx hardhat run scripts/capture/e2e-armada-circuits.ts --network hub` in `/src/armada-poc`, with
     `HUB_RPC` and the deployment file from E6. This gives shield, private transfer and unshield with real proofs
     verified on chain.
  3. Exits non-zero if either fails.
- Job `armada-nitro-e2e`, two stages in one job:
  1. `env/gates/nitro-e2e/prepare.ts`, run with armada-poc's toolchain in `/src/armada-poc` and its `lib/sdk`.
     - For two channels (random `channelId`s, `expectedHeld` 0), a test-account wallet shields USDC and syncs.
     - It then builds a real-proof transaction that unshields an ERC20 note to the adjudicator:
       - `UnshieldType.NORMAL`, `npk` = the adjudicator address;
       - `boundParams.adaptContract` = the adjudicator;
       - `boundParams.adaptParams` = `adjudicator.depositBinding(channelId, 0)`, read by `eth_call`.
     - Set the adapt fields through the engine's transaction-batch API (for example `TransactionBatch.setAdaptID`). If
       `lib/sdk` exposes no way to set them, stop and report the engine call you would need.
     - Writes `/env/nitro-e2e/deposits.json`: per channel `{channelId, amount, calldata}` for
       `depositFromNote(channelId, 0, [tx])`. Records proof time.
  2. `script/FixturenetScenario.s.sol`: `LocalScenario.s.sol`'s cooperative close and force close, with funding from
     `deposits.json` (sent by the test account) instead of testing-mode notes.
     - The challenge window comes from the job env (default 30 s, which spans real slots).
     - Verifies from chain state and the pool's `Shield` logs that each channel paid the user by shielding a note.
     - Prints `verified: both channels paid the user by shielding a note`.
- Both jobs added to `stacks/armada-nitro-fixturenet/stack.yml`. `stack/README.md` gets the full sequence: build,
  deploy, start, reconcile ×2, verify, nitro-e2e.

## Acceptance (paste output)
On a fresh fixturenet deployment: `run-job armada-env-reconcile` twice, `run-job armada-env-verify`, and `run-job
armada-nitro-e2e`. Paste each job's final lines and proof times.

Discrimination, in scratch copies (revert after), each run must fail:
- (a) `prepare.ts` binds `adaptParams` to `depositBinding(channelId, 1)`; the chain must reject with
  `Wrong adaptParams`.
- (b) `prepare.ts` sets `adaptContract` to the test account; rejected: the pool accepts it only from `adaptContract`.
- (c) Corrupt one byte of the proof in `deposits.json`; the Armada verifier rejects it. This proves real verification.
- (d) Run the scenario with a challenge window shorter than one slot interval and show the timing assertion it trips,
  or report why that is not discriminating.

Paste each failure line.

## Out of scope
Sepolia (E8), the 21-path acceptance suite (armada-client P2-08), the relayer.
