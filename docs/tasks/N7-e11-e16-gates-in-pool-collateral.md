> **Superseded (2026-10-22).** Contract-owned-notes lab book §3a R6 moves the
> adjudicator to a pool balance `balance[adjudicator][token]`, not notes, so this
> chunk's note-based mechanism is superseded, pending the R1-R5 pool work. See
> `docs/tasks/R6-adjudicator-balance-check.md`.

Chunk N7 · Family F4 · Points 8 · Route 5090
Depends on: N2a, N2b, N3

Read `docs/tasks/E11-aave-lido-channels.md`, `docs/tasks/E16-adjudicator-hardening.md`,
`env/gates/nitro-e2e/prepare.ts`, `script/FixturenetScenario.s.sol`,
`script/CustodianFrostScenario.s.sol`, and N1a/N1b/N2a/N2b/N3's diffs on `integrated` once merged.

Repo: `armada-nitro`. Branch: `integrated` (work in a `task/N7` branch cut from `integrated`).

## Goal
The `armada-nitro-e2e` gate (E16's acceptance surface) and the asset-level invariant tests E16
added both assumed the pre-N1 design: a channel funds by unshielding ERC-20 to the adjudicator's
raw balance, and holdings are `uint256` amounts. Both now run against the in-pool-collateral
design (N1a–N3): holdings are pool commitments, `depositFromNote` spends into a contract-owned
note, and payout runs only through `transfer(assetIndex, ...)`. This chunk updates the gate script
and the E16 invariant tests to match, with no behavior change beyond that.

## Deliver
- **S1 · `env/gates/nitro-e2e/prepare.ts` stage 1.** Replace the `UnshieldType.NORMAL` /
  `npk = adjudicator address` proof construction with N2a's contract-owned-output construction:
  build a `transact` (not unshield) whose output preimage is published in the clear, `npk` derives
  from the adjudicator's address, and `boundParams.adaptContract`/`adaptParams` still bind to
  `depositBinding(channelId, expectedHeld)`. Keep the per-channel dedicated-wallet pattern the
  file's header comment documents (same UTXO-selection collision reason).
- **S2 · E16's S1 test, "deposit of a non-allow-listed token is refused".** Re-run against
  `depositFromNote` only (N1a S3 deleted the base `deposit` entry point; the allow-list check in
  `isAsset` is unchanged, confirm it still gates `depositFromNote`'s `asset` read).
- **S3 · E16's S2 test, "a deposit of a fee-on-transfer test token is refused".** This test no
  longer applies as written: N2a's `depositFromNote` reads the credited amount from
  `pool.preimageOf(...).value`, not an ERC-20 balance delta, so no token can silently deliver less
  than `amount` through this path (the pool's own transact proof fixes the value). Replace it with
  a test that `depositFromNote` reverts when the pool's recorded preimage value does not match
  `amount` (already N2a's acceptance test — confirm it is present and cross-reference it here
  rather than duplicating it).
- **S4 · E16's S3 reentrancy test.** Still applies: `holdingsLock` is unchanged by N1a–N3. Confirm
  a re-entrant `depositFromNote` (via a hooking pool double, since there is no longer a hooking
  ERC-20 to misbehave) still reverts on `holdingsLock[channelId] != 0`.
- **S5 · E16's S4 per-asset exit test.** Re-run against N1b's commitment-based `transfer`: a
  two-asset channel where one asset's payout output construction is made to fail (a double
  `transactOwned` implementation that reverts for one asset's `npk`) still lets the other asset's
  `transfer(assetIndex, ...)` succeed.
- **S6 · `script/FixturenetScenario.s.sol` and `script/CustodianFrostScenario.s.sol`.** Confirm
  every payout call already uses `transfer(assetIndex, ...)` (E16 S4's existing rule, reinforced by
  N3 S2's revert of the bulk path). Update any call that does not compile against N3's override
  signatures.

## Acceptance (paste output)
`forge test --match-contract ArmadaNitroAdjudicatorTest` output for S2–S5's updated/replacement
tests, each failing on the commit before this task (either by referencing a deleted function, or
by exercising the old balance-delta behavior that no longer exists) and passing after.

Plus: `run-job armada-nitro-e2e` on a fresh fixturenet, pasted in full, showing stage 1's
contract-owned-output deposit, the cooperative close, and the force close through a real challenge
window, all against the in-pool-collateral adjudicator.

## Husband review
Check:
- S1's rewritten `prepare.ts` still produces a proof the real circuit accepts (a dry run against
  the fixturenet, not just a compiled script);
- S3's replacement test genuinely exercises the pool's attestation, not a value the adjudicator
  trusts from calldata;
- no gate script was edited to skip a check it used to run (list every deleted assertion in the
  report with the reason it no longer applies).

## Out of scope
E11's own content (Aave/Lido channel assets); a change to the allow-list's governance
model (still immutable, set at construction, per E16 S1).
