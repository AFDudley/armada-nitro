> **Superseded (2026-10-22).** Contract-owned-notes lab book §3a R6 moves the
> adjudicator to a pool balance `balance[adjudicator][token]`, not notes, so this
> chunk's note-based mechanism is superseded, pending the R1-R5 pool work. See
> `docs/tasks/R6-adjudicator-balance-check.md`.

Chunk N2a · Family F4 · Points 7 · Route 5090
Depends on: N1a, P2 (see "P2 interface this chunk assumes" below). N1b (the transfer/reclaim
payout side) is a parallel chunk; this deposit chunk does not use N1b's code and may land before
or after it.

Read `src/ArmadaNitroAdjudicator.sol` (`depositFromNote`, `depositBinding`),
`test/ArmadaNitroAdjudicator.t.sol`, `test/helpers/ArmadaNotes.sol` (`unshield`), and the
armada-laconic lab book `labbook/2026-10-18-contract-owned-notes-and-zk-channel-apps.md` §3
decisions 1, 2, 3, 9, 11, 21.

Repo: `armada-nitro`. Branch: `integrated` (work in a `task/N2a` branch cut from `integrated`).

## P2 interface this chunk assumes

Chunk P2 is pinned at armada-poc fffbbf31. It ships this surface, mirrored in
`src/armada/IArmadaPool.sol`: `transactOwned(Transaction[])`, `preimageOf(bytes32)`, and a
`BoundParams` with `ownerField` (bytes32) and `publicOutputs` (CommitmentPreimage[]). Confirm each
assumption below against that file. If the real interface differs, stop and report the difference.

1. A `transact` output can be contract-owned: the caller supplies the output's full
   `CommitmentPreimage` in the clear (instead of an encrypted `CommitmentCiphertext`), the pool
   checks `commitments[i] == poseidon(preimage)` with `preimage.npk` derived from a public `owner`
   address, and the pool stores `preimageOf[commitments[i]] = preimage` (lab book decision 1: "a
   `Transact` variant that derives the note keys from a public `owner` address"; decision 3: "the
   creator publishes the preimage in the creating transaction"). The *input* side of the
   transaction is unchanged: a normal user note, spent with the user's own EdDSA signature. Only
   the output is contract-owned. No unshield; value never leaves the pool.
2. `preimageOf` (N1a's assumption 1) is populated by this same call, in the same transaction,
   so a reader that calls `pool.transact(...)` then `pool.preimageOf(commitment)` in the next
   statement sees the stored value.
3. The exact function name and parameter shape are unconfirmed. If P2 exposes this as a new
   parameter on the existing `transact(Transaction[] calldata)` (for example an optional parallel
   `CommitmentPreimage[] calldata publicOutputs` array, matched to `commitments` by index) versus
   a separate entry point, use whichever P2 actually ships and note the discrepancy from this
   assumption in the report.

## Goal
`depositFromNote` funds a channel by having the depositor spend their own note into a fresh
contract-owned note at the adjudicator, inside the pool, instead of unshielding ERC-20 out to the
adjudicator's raw balance. The deposited value never leaves the pool (lab book decision 9).

## Deliver
- **S1 · Rewrite `depositFromNote`.** Replace the `UnshieldType.NORMAL` / `note.npk ==
  address(this)` / `IERC20.balanceOf` delta check with: the transaction's single output is a
  contract-owned commitment whose `preimage.npk` derives from `address(this)` (same derivation
  P2 defines for `transactOwned`'s `owner`, so the adjudicator can later spend it), whose
  `preimage.token.tokenAddress` is on `isAsset`, and whose `preimage.value` is `amount`
  (`depositFromNote`'s existing `amount`/`expectedHeld` parameters are unchanged). `depositBinding`
  keeps its current signature and meaning: the output's creation is bound, inside the proof, to
  `(channelId, expectedHeld)`.
- **S2 · Credit holdings from the pool's own record, not a balance delta.** After
  `pool.transact(transactions)` returns, require `pool.preimageOf(newCommitment).value == amount`
  (the pool attesting what it actually recorded), then set
  `holdings[asset][channelId] = newCommitment` (N1a's storage shape). Delete the
  `IERC20(asset).balanceOf` before/after read entirely: no ERC-20 moves through this contract.
- **S3 · Keep the reentrancy guard and the `held == expectedHeld` check**, now reading `held` via
  `heldValue(asset, channelId)` (N1a).
- **S4 · `Deposited` event** keeps its signature, emitting the new `heldValue`.

Keep existing conventions: an event for every holdings change; `SafeCast` for the pool's `uint120`
values where still used.

## Acceptance (paste output)
`forge test --match-contract ArmadaNitroAdjudicatorTest` output for these tests, each failing on
the commit before this task and passing after:
- `depositFromNote` with a correctly bound contract-owned output credits `holdings[asset][channelId]`
  to the new commitment, and `heldValue` reads back `amount`;
- `depositFromNote` whose output preimage value does not match `amount` reverts (the
  `pool.preimageOf(...).value == amount` check);
- `depositFromNote` whose output `npk` is not the adjudicator's derived owner address reverts
  (replaces the old `note.npk == address(this)` check, now read from `preimageOf`);
- the old unshield-based test fixtures in `test/helpers/ArmadaNotes.sol` (`unshield`) are either
  updated to build a contract-owned-output transaction, or a new helper is added; name which, in
  the report.

Plus: the full `forge test` suite compiles and passes.

## Husband review
Audit-critical. Check:
- the `amount` credited to `holdings` always comes from `pool.preimageOf`, never from a caller- or
  proof-supplied value the adjudicator did not ask the pool to attest;
- the contract-owned output's `npk` derivation cannot be spoofed to point at a different
  contract's owned notes (confirm P2's derivation formula and cite it in the report);
- no code path still reads `IERC20.balanceOf(address(this))` for deposit accounting.

## Out of scope
Payout as a spend (N2b); commitment-outcome finalization (N3).
