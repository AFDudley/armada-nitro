
# Chunk G7b · Family F3 · Points 5 · Route 5090

Depends on: G7a.
Handoff row moved: `notes/handoff-2026-10-20.md` §0.4, row "F3 governance", chunk G7
(split into G7a and G7b; see G7a's header for why).

Repo: `armada-poc`, gate extension in `armada-nitro`. Branch: `armada-poc` `integrated`
(`60a2f05`) with G1–G7a merged; `armada-nitro` `env/gates/` on its own `integrated`
(`55939ef`).

Read first:
- G7a's scenario script and gate step (this chunk's starting state).
- `armada-laconic/labbook/2026-10-18-treasury-governance-baal-safe-shielded.md` §4, the
  G7 check in full: "A run where a captured majority blocks an exit, or where a holder
  cannot exit at any time, must fail."
- `contracts/governance/ShieldedRagequit.sol` (G3's output): `ragequit`.
- `armada-sdk/src/tx/plan.ts` `planSpend` (line 392), `armada-sdk/src/tx/prove.ts`
  `prove` (line 81): the spend this chunk's scenario exercises against the Safe-owned
  shielded proceeds note from G7a.

## Goal

The same fixturenet run continues: a pool spend moves value, one participant ragequits at
any time — including immediately after a hostile vote — and exits with their pro-rata
share, proving a captured majority cannot block an exit.

## Deliver

- **S1 · Spend step.** Extend G7a's scenario: spend from a note already in the pool
  (any existing shielded holding on the fixturenet, or a fresh shield-then-spend pair) via
  `PrivacyPool.transact` (`contracts/privacy-pool/PrivacyPool.sol:146-148`), using the
  armada-sdk `planSpend`/`prove` flow, the same shape `armada-nitro-e2e` already proves for
  channel funding (`docs/ENVIRONMENT.md` §7).
- **S2 · Hostile-vote step.** Cast a Baal vote from a majority of outstanding ARM voting
  power (the fixturenet's funded accounts hold enough ARM between them after G7a's claim
  step) for a proposal that would drain the treasury, without executing it (the window
  before execution is exactly when ragequit must still work).
- **S3 · Ragequit step.** Have the account G7a used to vote (or a different claimant) call
  `ShieldedRagequit.ragequit` (G3) during the hostile proposal's voting or grace period, and
  confirm it succeeds and pays the correct pro-rata share — this is the gate's positive
  case for "a holder cannot exit at any time" failing to hold.
- **S4 · Negative case.** Add one run where the hostile proposal's grace period ends and
  the proposal executes, and ragequit still succeeds afterward at the new, smaller
  treasury balance, proving the captured majority cannot block the exit itself even if it
  drains funds (the case the G7 check names first).

## Acceptance (paste output)

The fixturenet gate run (G7a + G7b in sequence) showing: a real `transact` spend verified
on-chain; the hostile proposal recorded but not blocking `ragequit`; the ragequit payout
matching the bound G3's S4 enforces, both before and after the hostile proposal executes.

Fails before G7b exists (no ragequit step runs in any existing gate) and passes once
S1–S4 are wired. Plus: `armada-env-verify` and `armada-nitro-e2e` still pass unmodified
(CHUNK-RULES rule 3: this chunk extends the existing gates, it does not replace them).

## Husband review (gate review, not on the named audit-critical list, but review)

Confirm S4's negative case is a real proposal execution against the real
`ArmadaTreasuryGov`-equivalent spend path (Baal's own execute call), not a stand-in that
assumes the drain without running it.

## Out of scope

Sepolia and mainnet runs (CHUNK-RULES rule 4: fixturenet first). A new fixturenet harness
(CHUNK-RULES rule 3: this is an extension, not a new harness).
