Chunk N2b · Family F4 · Points 7 · Route 5090
Depends on: N1b, N2a, P2 (see "P2 interface this chunk assumes" below)

Read `src/ArmadaNitroAdjudicator.sol` (`_executeSingleAssetExit`), N1b's diff on `integrated` once
merged, `test/ArmadaNitroAdjudicator.t.sol`, and the armada-laconic lab book
`labbook/2026-10-18-treasury-governance-baal-safe-shielded.md` §3 decisions 15, 22 and §4 ("N8
gate").

Repo: `armada-nitro`. Branch: `integrated` (work in a `task/N2b` branch cut from `integrated`).

## P2 interface this chunk assumes

Chunk P2 (armada-poc, not yet briefed) must add this surface. State these as the contract P2 must
meet. If the real P2 interface differs, stop and report the difference instead of guessing.

1. `function cumulativeFees(address asset) external view returns (uint256);` A per-asset running
   total of fees the pool has recognized, read by G4's RevenueLock rewrite (governance lab book
   §4, G4 row) and by N8's gate.
2. `function feeRecipient() external view returns (bytes32 npk);` The Safe's registered note
   public key. `transact`/N2a's contract-owned-output mechanism recognizes an output whose `npk`
   equals `feeRecipient()` as a fee-tagged output: the pool both stores its preimage (as any
   contract-owned output does, N2a assumption 1) and, in the same call,
   `cumulativeFees[asset] += value`. This matches governance lab book decision 15: "`ShieldModule`
   creates the fee note to the Safe's `npk` and increments `cumulativeFees` in the same
   permissionless call."
3. The fee-recognition rule applies identically whether the output is created by a user's own
   `transact` call (a swap fee inside a channel) or by the adjudicator's payout spend (this
   chunk). The pool does not distinguish the caller; it only checks `npk == feeRecipient()`.

## Goal
A `SHIELD`-allocation payout stops calling `pool.shield` against a raw ERC-20 balance (N1a removed
that balance) and becomes one more output of the same `transactOwned` spend N1b's `transfer`
already performs. A payout that carries a fee allocation tags that output to the Safe so it counts
toward `cumulativeFees`.

## Deliver
- **S1 · Fold `SHIELD` into N1b's single spend.** Delete `_executeSingleAssetExit` and
  `_apply_transfer_interactions`'s separate `pool.shield` call. In N1b's `transactOwned` call
  (S1 of that chunk), a `SHIELD`-type allocation becomes one more output: `npk` =
  `allocation.destination` (the recipient's own note key, not contract-owned — this output is not
  re-spendable by the adjudicator, so it uses an ordinary encrypted `CommitmentCiphertext` from
  `allocation.metadata`, as today's `ShieldRequest.ciphertext` did), `value` =
  `allocation.amount`.
- **S2 · Fee-tagged payout.** A payout allocation whose `destination` equals `pool.feeRecipient()`
  is still paid as a `SHIELD`-type output in the same spend (S1), with no special-case branch: the
  pool recognizes it by `npk` and bumps `cumulativeFees` itself (P2 assumption 2). This chunk adds
  no fee logic of its own; it only stops routing that allocation through the old `pool.shield`
  path.
- **S3 · Zero-amount allocations are still skipped**, the same rule `_executeSingleAssetExit` used
  (the pool rejects a zero-value output).
- **S4 · `isExternalDestination` payouts stay as `_transferAsset`** only for the ETH/raw-asset
  path this family does not touch; confirm no `SHIELD` allocation ever reaches that branch (it is
  mutually exclusive by `allocationType` already) and leave it unchanged.

## Acceptance (paste output)
`forge test --match-contract ArmadaNitroAdjudicatorTest` output for these tests, each failing on
the commit before this task and passing after:
- a finalized channel's `transfer` with one `SHIELD` allocation to a plain recipient pays a note
  of the allocated amount, checked via `pool.preimageOf` on the resulting commitment or via the
  pool's `Shield`/`Transact` log, whichever N2a's helper update exposes;
- a finalized channel's `transfer` with one `SHIELD` allocation to `pool.feeRecipient()` leaves
  `pool.cumulativeFees(asset)` increased by exactly the allocated amount (against a test double or
  the real pool if P2 has merged by the time this runs — state which, in the report);
- the old `_executeSingleAssetExit`/`pool.shield` call path is gone: `grep -n 'pool.shield'
  src/ArmadaNitroAdjudicator.sol` returns nothing.

Plus: the full `forge test` suite compiles and passes.

## Husband review
Audit-critical. Check:
- a payout's fee tagging is entirely the pool's decision (by `npk == feeRecipient()`), so the
  adjudicator cannot under- or over-report a fee by mislabeling an allocation;
- no payout path can create an output the pool does not record a preimage for (every payout note
  must be provable later, same invariant as N2a's deposit side);
- `cumulativeFees` can only increase through a real, value-moving output, never through a call
  with no corresponding spend (ties to G4's "inflates the counter for free" check).

## Out of scope
Commitment-outcome finalization branching (N3); the N8 gate itself, which proves the full
swap-fee-to-RevenueLock path end to end; RevenueLock's own rewrite (G4, a different family).
