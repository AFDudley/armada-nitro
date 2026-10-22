Chunk N2b · Family F4 · Points 5 · Route 5090
Depends on: N1b, N2a, P2 (see "P2 interface this chunk assumes" below)

Read `src/ArmadaNitroAdjudicator.sol` (`_executeSingleAssetExit`), N1b's diff on `integrated` once
merged, and `test/ArmadaNitroAdjudicator.t.sol`.

Repo: `armada-nitro`. Branch: `integrated` (work in a `task/N2b` branch cut from `integrated`).

## P2 interface this chunk assumes

Chunk P2 is pinned at armada-poc a6c77939. N1b and N2a already added the pool interface this chunk
uses (`transactOwned`, `preimageOf`) to `src/armada/IArmadaPool.sol`. This chunk adds no new pool
view. Confirm `transactOwned` is present on `integrated` before you start. If it differs, stop and
report the difference instead of guessing.

## Goal
A `SHIELD`-allocation payout stops calling `pool.shield` against a raw ERC-20 balance (N1a removed
that balance) and becomes one more output of the same `transactOwned` spend N1b's `transfer`
already performs. There is no protocol fee on a payout (operator ruling 2026-10-22), so a payout
is a plain output, with no fee tag and no `cumulativeFees` coupling.

## Deliver
- **S1 · Fold `SHIELD` into N1b's single spend.** Delete `_executeSingleAssetExit` and
  `_apply_transfer_interactions`'s separate `pool.shield` call. In N1b's `transactOwned` call
  (S1 of that chunk), a `SHIELD`-type allocation becomes one more output: `npk` =
  `allocation.destination` (the recipient's own note key, not contract-owned — this output is not
  re-spendable by the adjudicator, so it uses an ordinary encrypted `CommitmentCiphertext` from
  `allocation.metadata`, as today's `ShieldRequest.ciphertext` did), `value` =
  `allocation.amount`.
- **S2 · Zero-amount allocations are still skipped**, the same rule `_executeSingleAssetExit` used
  (the pool rejects a zero-value output).
- **S3 · `isExternalDestination` payouts stay as `_transferAsset`** only for the ETH/raw-asset
  path this family does not touch; confirm no `SHIELD` allocation ever reaches that branch (it is
  mutually exclusive by `allocationType` already) and leave it unchanged.

## Acceptance (paste output)
`forge test --match-contract ArmadaNitroAdjudicatorTest` output for these tests, each failing on
the commit before this task and passing after:
- a finalized channel's `transfer` with one `SHIELD` allocation to a plain recipient pays a note
  of the allocated amount, checked via `pool.preimageOf` on the resulting commitment or via the
  pool's `Shield`/`Transact` log, whichever N2a's helper update exposes;
- the old `_executeSingleAssetExit`/`pool.shield` call path is gone: `grep -n 'pool.shield'
  src/ArmadaNitroAdjudicator.sol` returns nothing.

Plus: the full `forge test` suite compiles and passes.

## Husband review
Audit-critical. Check:
- no payout path can create an output the pool does not record a preimage for (every payout note
  must be provable later, same invariant as N2a's deposit side).

## Out of scope
Commitment-outcome finalization branching (N3).
