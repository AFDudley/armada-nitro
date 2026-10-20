# N9: Gate — `LedgerForceMoveApp` channel on the fixturenet

Chunk N9 · Family F2 · Points 9 · Route 5090
Depends on: N4, N5. N6 is not required (this gate exercises the ledger app,
not the example game).

Repo: `armada-nitro`. Branch: `integrated`. Work in a new worktree from
`origin/integrated`. This chunk extends the existing `armada-nitro-e2e` gate;
it does not build a new fixturenet or a new job.

Read `docs/ENVIRONMENT.md` §7 (the `armada-nitro-e2e` gate's two stages),
`stack/README.md` lines ~293–325 (the gate's narrative description and the
exact run command), `env/gates/nitro-e2e/prepare.ts` in full (stage 1: builds
`deposits.json` for `CHANNEL_COUNT` channels, each a real-proof unshield to
the adjudicator bound to `consensusApp` as `appDefinition`), `script/
FixturenetScenario.s.sol` in full (stage 2: `setUpHub`, `cooperativeClose`,
`openAndChallenge`, `earlySettle`, `settle`, `verify`, and the `_fund`,
`_fixedPart`, `_state`, `_deposit`, `_ctx` helpers), `test/helpers/
ChannelStates.sol`, and `stack/compose-jobs/docker-compose-armada-nitro-e2e.yml`
(the exact `run_script` sequence this chunk adds to). Read `src/apps/
LedgerForceMoveApp.sol` and `test/fixtures/zk-app/ledger/{valid-move,
insufficient-balance}.json` (N5; if missing in your worktree, stop and
report — N9 depends on N5).

## Goal

Prove, on the real fixturenet, that a channel whose `appDefinition` is a
deployed `LedgerForceMoveApp` opens, rejects a bad proof off-chain, survives
a challenge with the valid proven state, and pays out correctly after the
challenge window. This is the one end-to-end check that N4 and N5's Solidity
and circuit work actually compose into a real channel, not just unit tests.

## Deliver

- **S1 · Deploy phase.** Add `deployLedgerApp()` to `FixturenetScenario.s.sol`.
  It reads the converted verifying key from `test/fixtures/zk-app/ledger/
  vkey.json` (the same fixture `LedgerForceMoveApp.t.sol` loads — reuse that
  loading code, do not re-derive the conversion), deploys `LedgerForceMoveApp`
  with it, and writes the deployed address with `vm.writeFile('deployments/
  ledger-app-address', vm.toString(address(app)))` (same pattern as the
  existing `START_BLOCK`/`HUB_START_BALANCE` constants; `./deployments` is
  already `read-write` in `foundry.toml`'s `fs_permissions`). Run this phase
  before stage 1 (`prepare.ts`), since stage 1 needs the deployed address to
  bind `appDefinition` into channel 2's `channelId`.

- **S2 · `prepare.ts`: a third channel.** `CHANNEL_COUNT` is currently a fixed
  `2` (or `1` under the discrimination env vars) and every channel binds
  `channelId` to the single `consensusApp` address
  (`[participants, channelNonce, consensusApp, CHALLENGE_DURATION]`, line
  ~371–374). Change this to an array `appDefinitions[i]`, where
  `appDefinitions[0] = appDefinitions[1] = consensusApp` and, when
  `LEDGER_APP_ADDRESS` is set, `appDefinitions[2] = LEDGER_APP_ADDRESS` and
  `CHANNEL_COUNT = 3`. Everything else about channel 2's construction
  (shield, real-proof unshield to the adjudicator, `UnshieldType.NORMAL`,
  `npk` = adjudicator) is identical to channels 0 and 1 — only the
  `appDefinition` used in the `channelId` hash differs. Fund channel 2 for
  150 USDC gross (matching channels 0/1's existing `SHIELD_AMOUNT` constant),
  so its net deposit is enough to cover the 150-unit total N5's committed
  `valid-move.json` fixture conserves (`balance0Prev=100, balance1Prev=50`).

- **S3 · Bad-proof refusal phase.** Add `ledgerBadProofRefused()` to
  `FixturenetScenario.s.sol`. No `vm.broadcast`, no transaction — this is the
  counterparty's own off-chain check, the same check `cooperativeClose`'s
  counterparty would run before countersigning. Build the `fixedPart` for
  channel 2 (`appDefinition` = the address written in S1), build a candidate
  `VariablePart` whose `appData` carries N5's committed
  `insufficient-balance` fixture's proof and public inputs (if that fixture
  does not exist because N5 only committed `valid-move` and
  `p0-wins`/`p1-wins`-style winning fixtures, flip one bit of the valid
  proof's `a.x` instead — document which you used), and call
  `LedgerForceMoveApp(ledgerApp).stateIsSupported(fixedPart,
  singleElementProofArray, candidate)` as a plain `view` call. Assert the
  returned `bool` is `false`. Log the returned revert-reason string.

- **S4 · Challenge and finalize phase.** Add `ledgerChallenge()`: fund
  channel 2 (`_fund`, reusing the existing helper), build a chained pair of
  states from N5's `valid-move.json` fixture — a prior state (turnNum N,
  `appData` encoding `prevCommitment` with `publicInputs[1]` equal to the
  fixture's `nextCommitment`... use the fixture's own `prevCommitment`/
  `nextCommitment` pair directly: prior state's `appData.publicInputs =
  [X, prevCommitment]` for some prior-prior value is not available from a
  single fixture, so treat the fixture's move itself as the channel's first
  and only move: `proof[0]` is a state whose outcome and `appData` reflect
  the channel's starting balances (100 USDC to the user, 50 USDC to the
  custodian, `appData.publicInputs = [0, prevCommitment]` with `0` as a
  placeholder opening value never checked by `LedgerForceMoveApp` itself —
  state the simplification plainly in your report if you take it), and
  `candidate` is the state after the fixture's proven move (`outcome` =
  70 USDC to the user, 80 USDC to the custodian — the fixture's
  `balance0Next`/`balance1Next` — `appData.publicInputs = [prevCommitment,
  nextCommitment]`, the real proof). Sign both with `ChannelStates.
  signedByBoth`. Challenge with `c.adjudicator.challenge(fp, proof,
  signedCandidate, challengerSig)`, the same call `openAndChallenge` makes.
  Add `ledgerSettle()`, called after the same `CHALLENGE_DURATION` wait the
  existing `settle()` phase uses, paying out via `_settlePerAsset` (reuse the
  helper, it is asset-count-agnostic).

- **S5 · Verify phase.** Add `ledgerVerify()`: assert
  `c.adjudicator.holdings(address(c.usdc), channelId2) == 0`, and that the
  `Shield` logs (same `ArmadaNotes.decodeShield`/`SHIELD_EVENT` pattern
  `verify()` uses) show a note of `70e6` to the user's payout `npk`. This
  proves the on-chain payout matches the hidden-balance proof's revealed
  final balances, which is the point at which this channel's balances stop
  being hidden (they are necessarily public at settlement — only the
  balances during play are hidden, since no intermediate state is ever
  submitted on-chain).

- **S6 · Wire the gate.** In `stack/compose-jobs/docker-compose-armada-nitro-e2e.yml`,
  add, before the existing stage-1 `npx hardhat run` call:
  ```
  run_script script/FixturenetScenario.s.sol --sig 'deployLedgerApp()'
  export LEDGER_APP_ADDRESS="$$(cat deployments/ledger-app-address)"
  ```
  and pass `LEDGER_APP_ADDRESS="$$LEDGER_APP_ADDRESS"` into the stage-1
  `npx hardhat run` environment block alongside the existing `MANIFEST_PATH`/
  `DEPOSITS_OUTPUT`/etc. variables. After the existing `settle()`/`verify()`
  lines, add:
  ```
  run_script script/FixturenetScenario.s.sol --sig 'ledgerBadProofRefused()'
  run_script script/FixturenetScenario.s.sol --sig 'ledgerChallenge()'
  sleep $$((CHALLENGE_DURATION + 3))
  run_script script/FixturenetScenario.s.sol --sig 'ledgerSettle()'
  forge script script/FixturenetScenario.s.sol --sig 'ledgerVerify()' --rpc-url "$$HUB_RPC"
  ```
  Do not change the existing channel 0/1 phases or their ordering.

## Acceptance (paste output)

The exact gate command this chunk extends:
```
laconic-so deployment --dir <deployment> run-job armada-nitro-e2e
```
(per `stack/README.md`'s documented invocation; run it against a fixturenet
deployment reconciled by `armada-env-verify` first, same precondition the
existing gate already states). Paste the job's output:
- `deployLedgerApp()`'s broadcast, showing the deployed address;
- stage 1's log line for channel 2 (`channel <id>: channelId=... proof
  time=...ms`);
- `ledgerBadProofRefused()`'s logged `false` / revert-reason line — this
  check fails before this task (no `ledgerBadProofRefused` phase exists) and
  passes after;
- the challenge and settle broadcasts for channel 2;
- `ledgerVerify()`'s clean exit (no `require` failure) — this fails before
  this task (channel 2, the deploy phase, and `ledgerVerify` do not exist)
  and passes after.

Plus: the existing gate's channel 0 (`cooperativeClose`) and channel 1
(`openAndChallenge`/`earlySettle`/`settle`) output is unchanged — paste
`verify()`'s output showing both still pass.

## Husband review

Not on the audit-critical list (P1, P2, N1, N2, G3), but touches a live
fixturenet payout path. The husband checks:
- `ledgerChallenge`'s candidate `outcome` allocations (70/80 USDC) literally
  equal N5's `valid-move.json` fixture's `balance0Next`/`balance1Next` — a
  mismatch here would mean the on-chain payout does not match what the proof
  attests to, defeating the whole point of the check.
- `ledgerBadProofRefused` asserts `false` from a real `stateIsSupported`
  call, not from a `try/catch` that would also swallow an unrelated revert.
- The S2 simplification (prior state's `appData.publicInputs[0]` as an
  unchecked placeholder) is called out plainly in the worker's report, since
  it is a real gap relative to N5's `LedgerForceMoveApp` (which does check
  `proof[0]`'s public inputs against `candidate`'s) — confirm it does not
  silently pass `LedgerForceMoveApp`'s own commitment-chain check for the
  wrong reason.

## Out of scope

A production verifying key (this gate uses N5's dev-ceremony key, same as
every other fixturenet gate uses dev-mode artifacts). `MatchingPennies`/N6.
A hub-fronted or multi-asset ledger channel. Changing the reconciler or the
manifest schema — the deployed app's address is passed through
`LEDGER_APP_ADDRESS`, not a new manifest field, to keep this chunk's
footprint to the gate job and the scenario script.
