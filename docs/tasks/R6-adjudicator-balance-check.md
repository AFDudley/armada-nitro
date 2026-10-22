# R6 check: the adjudicator holds channel collateral as a pool balance

design · 2026-10-22

Contract-owned-notes lab book
(`armada-laconic/labbook/2026-10-18-contract-owned-notes-and-zk-channel-apps.md`)
§3a replaces decisions 1, 2, 3, 9 and 11 for contract owners. A contract owner
holds a public per-token balance `balance[owner][token]` in the pool, not notes.
§3a R6 says the adjudicator probably moves to `balance[adjudicator][token]` too,
and asks for a check that the mechanism works for channel collateral before F4
continues. This is that check.

## Verdict

Feasible, given R1-R5 (the contract-owner balance) are built. It reuses the
existing `Transact` circuit: no new circuit, no new ceremony.

## Today (decisions 9 and 11, note-based)

`ArmadaNitroAdjudicator.depositFromNote` (`src/ArmadaNitroAdjudicator.sol:141`)
stores `holdings[asset][channelId] = transaction.commitments[0]` — an
adjudicator-OWNED note's commitment. `heldValue` (:54-58) reads the value
through `pool.preimageOf`. `transfer`/`conclude` move the commitment
(`MultiAssetHolder.sol:194`, `NitroAdjudicator.sol:95`). The channelId is bound
by `adaptParams == depositBinding(channelId, expectedHeld)`.

## Under R6 (balance-based)

- **Fund (R2 credit).** The deposit's `transact` unshields into
  `balance[adjudicator][token]` (recipient is the balance, not an ERC-20
  transfer and not an owned note), channelId bound by the same `depositBinding`.
  The pool credits `balance += value` (existing `Transact` circuit,
  `Transact.circom:103-112` — contracts only). The adjudicator records
  `holdings[asset][channelId] += value`, now an AMOUNT.
- **Hold.** `balance[adjudicator][token]` (pool, aggregate over channels) plus
  `holdings[asset][channelId]` (adjudicator, per-channel amount). `heldValue`
  reads the amount directly; it drops `pool.preimageOf`.
- **Pay out (R3 debit).** The finalized outcome lets the adjudicator
  (`msg.sender == adjudicator`, the owner) debit `balance -= sum(amounts)` and
  the pool creates each payee's shielded note from the internal balance, with no
  shield fee, decrementing `holdings[asset][channelId]`.

## Key risk: per-channel attribution

The pool balance is per-TOKEN (aggregate). The channel attribution is the
adjudicator's `holdings`. The invariant
`sum_over_channels(holdings[asset][channelId]) == balance[adjudicator][asset]`
must hold, so every credit to `balance[adjudicator]` must go through a
channelId-binding deposit. R2 lets any payer credit any contract owner, so a
stray unshield to the adjudicator's balance would break the invariant. The rule
needs an operator ruling.

## The proposed check (forge, production deploy, real proofs)

1. Fund: an unshield credit into `balance[adjudicator][token]` (channel bound)
   raises `balance` AND `holdings[asset][channelId]` by the amount.
2. Pay out: a finalized channel debits `balance`, creates the payees' shielded
   notes (Shield events), decrements `holdings`; no shield fee is charged.
3. Auth: a debit by any caller other than the adjudicator reverts (R3).
4. Invariants (R5): `accounted[token] == notes + sum(balance[owner])`;
   `sum_channels(holdings) == balance[adjudicator][asset]`.

## N-chunk impact

- **N1a** (merged): superseded in semantics — `holdings` as a commitment plus a
  `preimageOf` read becomes `holdings` as an amount plus a direct read, plus the
  pool balance. The mapping stays; it needs a re-do.
- **N1b**: superseded — the commitment transfer (`transactOwned`) becomes a
  plain `holdings`-amount move; no owned note, no circuit.
- **N2a**: superseded — `depositFromNote`-as-spend becomes an unshield credit
  (R2); contracts only, no new circuit.
- **N2b**: superseded — payout-as-spend becomes the owner-only debit into notes
  (R3). There is no protocol swap fee, so no fee tag (operator ruling
  2026-10-22; treasury decision 23 struck).
- **N3**: affected — commitment-outcome finalization becomes the debit plus
  payee-note creation.
- **N7**: affected — E11/E16 in-pool collateral is a balance, not notes.
- **N8**: withdrawn — there is no protocol swap fee.

## Conclusion

F4 can continue on the balance design, but every note-based F4 chunk is
superseded. R6 depends on R1-R5 (the contract-owner balance) being built first.
R7 (removing `transactOwned`, `verifyOwned`, `ownerField` and the optional
`publicOutputs`) waits on R6 landing.
