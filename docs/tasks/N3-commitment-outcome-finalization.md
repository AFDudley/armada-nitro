> **Superseded (2026-10-22).** Contract-owned-notes lab book §3a R6 moves the
> adjudicator to a pool balance `balance[adjudicator][token]`, not notes, so this
> chunk's note-based mechanism is superseded, pending the R1-R5 pool work. See
> `docs/tasks/R6-adjudicator-balance-check.md`.

Chunk N3 · Family F4 · Points 8 · Route 5090
Depends on: N1a, N1b, N2a, N2b

Read `src/nitro/NitroAdjudicator.sol` (`concludeAndTransferAllAssets`, `transferAllAssets`,
`_transferAllAssetsBody`), `src/ArmadaNitroAdjudicator.sol`, `src/nitro/MultiAssetHolder.sol`
(`transfer`, post-N1b), `docs/tasks/E16-adjudicator-hardening.md` S4 ("No payout depends on
`transferAllAssets` or `concludeAndTransferAllAssets`, and no script tries one payout path and
then falls back to another"), and
`script/FixturenetScenario.s.sol`/`script/CustodianFrostScenario.s.sol`.

Repo: `armada-nitro`. Branch: `integrated` (work in a `task/N3` branch cut from `integrated`).

## Goal
`NitroAdjudicator`'s bulk finalization path (`_transferAllAssetsBody`, used by both
`transferAllAssets` and `concludeAndTransferAllAssets`) does raw `uint256` arithmetic on
`holdings[asset][channelId]`. After N1a that storage slot holds a `bytes32` commitment, not an
amount, so the inherited bulk path cannot run. This chunk makes the adjudicator finalize a channel
(set its status to finalized) without the inherited bulk payout, and routes every payout through
`MultiAssetHolder.transfer(assetIndex, ...)` (N1b, already commitment-aware and already E16 S4's
required per-asset path).

## Deliver
- **S1 · Finalize-only `concludeAndTransferAllAssets` override.** In `ArmadaNitroAdjudicator`,
  override `concludeAndTransferAllAssets` to call `_conclude(fixedPart, candidate)` and stop:
  no `_transferAllAssetsBody` call. A caller that wants a payout calls `transfer(assetIndex, ...)`
  separately, once per asset, after this returns (the same pattern E16 S4 already requires for
  `script/FixturenetScenario.s.sol` and `script/CustodianFrostScenario.s.sol`).
- **S2 · Revert the bulk payout entry points.** Override `transferAllAssets` in
  `ArmadaNitroAdjudicator` to `revert('Use transfer(assetIndex, ...)')`. This is the commitment-
  outcome finalization branch: a channel with commitment-typed holdings has no well-defined bulk
  `_transferAllAssetsBody` behavior, so the override makes that explicit instead of leaving the
  inherited function to misread `holdings` as a `uint256`.
- **S3 · Confirm no in-repo caller still depends on the reverted path.** Grep `script/`, `test/`,
  and `env/gates/` for `transferAllAssets` and `concludeAndTransferAllAssets`; list every call site
  in the report and confirm each either moves to per-asset `transfer` (already E16 S4's rule) or is
  deleted as dead.
- **S4 · `_requireChannelFinalized` stays correct** for the per-asset `transfer` path: a channel
  finalized by S1's `_conclude`-only override satisfies the same finalized-status check
  `transfer`'s `_apply_transfer_checks` already runs, so no change is needed there — confirm this
  with the test below rather than asserting it.

## Acceptance (paste output)
`forge test --match-contract ArmadaNitroAdjudicatorTest` output for these tests, each failing on
the commit before this task (today's `concludeAndTransferAllAssets` would revert differently, on
the commitment-type mismatch introduced by N1a/N2a, not for this reason) and passing after:
- `concludeAndTransferAllAssets` finalizes a channel (status check) and leaves every asset's
  `holdings[asset][channelId]` untouched (still the pre-conclude commitment);
- a subsequent `transfer(assetIndex, ...)` call on that now-finalized channel pays out correctly,
  for a channel with two assets, each paid by its own `transfer` call;
- a direct call to `transferAllAssets` on a finalized channel reverts with
  `'Use transfer(assetIndex, ...)'`.

Plus: the existing `forge test` suite and the `armada-nitro-e2e` gate still pass on a fresh
fixturenet (N7 extends this gate's scenario to cover in-pool collateral; this chunk only needs the
gate's existing cooperative-close and force-close scenarios to keep passing with S1/S2 in place).

## Husband review
Audit-critical. Check:
- S1's override truly stops before any payout side effect; `_conclude` alone must not move or
  record any commitment;
- S2's revert cannot be bypassed by calling the base `MultiAssetHolder`/`NitroAdjudicator`
  function directly (confirm `ArmadaNitroAdjudicator` is the only entry point deployed, or that
  the override is `virtual override` and genuinely replaces the base selector, not an overload);
- every removed or redirected call site named in S3's report is accounted for, with no silent
  fallback to the old bulk path left in a script.

## Out of scope
The N7 gate updates that prove the new per-asset-only payout flow end to end on the fixturenet
(this chunk only adds the unit tests).
