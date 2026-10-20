Chunk N1b · Family F4 · Points 6 · Route 5090
Depends on: N1a, P2 (see "P2 interface this chunk assumes" below)

Read `src/nitro/MultiAssetHolder.sol` (`transfer`, `reclaim`, `compute_transfer_effects_and_interactions`,
`compute_reclaim_effects`), `src/ArmadaNitroAdjudicator.sol` (`_executeSingleAssetExit`), N1a's
diff on `integrated` once merged, and the armada-laconic lab book
`labbook/2026-10-18-contract-owned-notes-and-zk-channel-apps.md` §3 decisions 9, 11.

Repo: `armada-nitro`. Branch: `integrated` (work in a `task/N1b` branch cut from `integrated`).

## P2 interface this chunk assumes

Same `preimageOf` and `transactOwned` from N1a's brief. This chunk additionally assumes
`transactOwned` accepts a transaction whose nullifier spends the adjudicator's current commitment
and whose outputs mint zero or more new owned commitments in one call, so a transfer that pays out
part of a channel's collateral and keeps the remainder can do both in one pool call. If P2's
`transactOwned` instead requires one spend per call, stop and report the mismatch.

## Goal
`transfer` and `reclaim` move collateral between a finalized channel's commitment and its payees'
commitments by spending the old commitment and minting the new ones in the pool, instead of
decrementing a `uint256` and calling `_executeSingleAssetExit`'s raw-asset interactions.

## Deliver
- **S1 · `transfer`'s interaction step.** Replace `_apply_transfer_interactions`'s call into
  `_executeSingleAssetExit` with a `pool.transactOwned` call: one input nullifying
  `holdings[asset][fromChannelId]`'s current commitment, one output per non-zero
  `exitAllocations` entry (owner-derived `npk` = the allocation's `destination` when it is an
  external note recipient; unchanged for a `SHIELD`-type allocation, which N2b owns), and, if
  `totalPayouts < initialAssetHoldings`, one more output that re-mints the adjudicator's
  remaining collateral as a fresh owned commitment.
- **S2 · `transfer`'s effects step.** `_apply_transfer_effects` writes the new commitment (or
  `bytes32(0)` if the channel's collateral in this asset is now fully paid out) into
  `holdings[asset][fromChannelId]`, read back from the `transactOwned` call's return or from the
  known deterministic commitment (circuit/output ordering — read `lib/armada-poc`'s commitment
  derivation to confirm which, and cite the exact function in the report).
- **S3 · `reclaim`.** Guarantees are not Armada-pool commitments (they are a go-nitro allocation
  type that never reached the pool). `compute_reclaim_effects` is unchanged. Only its one write
  path, `_apply_reclaim_effects`, moves its holdings read through `heldValue`/new commitment
  write, the same pattern as S2.
- **S4 · `_executeSingleAssetExit` for non-`SHIELD` external payouts.** With S1 in place,
  `ArmadaNitroAdjudicator._executeSingleAssetExit` no longer calls `_transferAsset` for an
  external destination; delete that branch and `holdings[asset][...] += allocation.amount` for a
  non-external, non-`SHIELD` destination (channel-to-channel collateral moves are not in this
  family's scope — confirm no test exercises it, or report if one does).

## Acceptance (paste output)
`forge test --match-contract MultiAssetHolderCommitmentTest` and
`--match-contract ArmadaNitroAdjudicatorTest` output for:
- a `transfer` of part of a finalized channel's collateral pays the named destination a fresh
  owned commitment of the paid amount, and leaves `holdings[asset][channelId]` pointing at a
  fresh commitment of the remainder (fails before S1/S2 exist, passes after);
- a `transfer` that pays out the channel's entire collateral in one asset sets
  `holdings[asset][channelId]` to `bytes32(0)`;
- `reclaim` moves a guarantee's value into the target channel's commitment, read by `heldValue`
  (fails before S3, passes after).

Plus: the existing `forge test` suite compiles and passes end to end. N1a leaves the suite green,
so this chunk keeps it green: `forge build` and `forge test` pass before and after this chunk.

## Husband review
Audit-critical. Check:
- every payout spends the exact commitment recorded in `holdings`, never a stale or
  attacker-supplied one;
- the remainder-recredit output in S1 always carries the adjudicator's own owner-derived `npk`,
  never a caller-supplied one;
- `totalPayouts == initialAssetHoldings` (full payout) mints no remainder output, so
  `holdings[asset][channelId]` cannot be left pointing at a `0`-value commitment.

## Out of scope
`depositFromNote` and the `deposit` entry point (N2a); `SHIELD`-type payouts (N2b); finalization
branching (N3).
