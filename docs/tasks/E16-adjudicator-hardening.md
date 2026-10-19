# E16 Adjudicator hardening for multi-asset hub channels

Depends on: E10. Read `src/ArmadaNitroAdjudicator.sol`, `src/nitro/MultiAssetHolder.sol` (`deposit`, `transfer`,
`reclaim`), `src/nitro/NitroAdjudicator.sol` (`transferAllAssets`, `concludeAndTransferAllAssets`),
`src/HubCustodian.sol`, and the armada-laconic design this task implements:
[15 · Hub yield and swaps as channel state](https://afdudley.github.io/armada-laconic/engineering/15-hub-yield-and-swaps.html)
(invariants I1–I7; ADR-0017). E11 puts several assets in one channel; this task makes the adjudicator enforce the
invariants that requires before E11 runs.

## Goal
The adjudicator accepts only assets whose balances change exactly by transfers, credits exactly what it receives on
every deposit path, cannot be re-entered while it changes holdings, and lets each asset of a finalized channel exit
even when another asset's payout reverts.

## Deliver
- **S1 · Asset allow-list (I1, I6).** An immutable allow-list set in the constructor. `deposit` and `depositFromNote`
  revert for any other asset. Fixturenet list: USDC, WETH, `wstETH`, `waUSDC`. `stETH` and `aUSDC` are not listed.
  The reconciler's `armada_nitro` module passes the list from the manifest's `assets`.
- **S2 · Balance-delta `deposit` (I1).** Override the inherited go-nitro `deposit`: credit the measured balance change
  and require it to equal `amount` (as `depositFromNote` already does for `note.value`).
- **S3 · Reentrancy guard (I6).** One guard on every function that changes `holdings`: `deposit`, `depositFromNote`,
  `transfer`, `transferAllAssets`, `concludeAndTransferAllAssets`, `reclaim`.
- **S4 · Per-asset exit (I5).** No contract change expected: `transfer(assetIndex, ...)` already pays one asset. Prove
  it with the test below. Every script that pays out a finalized channel pays each asset with its own
  `transfer(assetIndex, ...)` call: the watchtower, the `armada-nitro-e2e` scenario (`script/FixturenetScenario.s.sol`),
  and the hub's close in `script/CustodianFrostScenario.s.sol`. A hub channel holds several assets once E11 adds swaps,
  so the hub's close is under this rule even while its channel holds only USDC. No payout depends on
  `transferAllAssets` or `concludeAndTransferAllAssets`, and no script tries one payout path and then falls back to
  another.
- **S5 · Pin `HubCustodian`'s pragma** to an exact version (it is `^0.8.37`; the adjudicator is already `0.8.17`).
- **S6 · No rate on the settlement path (I4).** The adjudicator imports no ERC-4626 interface and calls no exchange
  rate; check it in the forge tests as a source-level assertion.

Keep the existing conventions: `SafeERC20` for every token call, `forceApprove` before `pool.shield`, `SafeCast` for
the pool's `uint120` values, an event for every holdings change.

## Acceptance (paste output)
`forge test` output for these tests, each failing on the commit before this task and passing after:
- deposit of a non-allow-listed token is refused, by `deposit` and by `depositFromNote` (S1);
- a `deposit` of a fee-on-transfer test token (delivers less than `amount`) is refused (S2);
- a re-entrant deposit through a hooking test token is refused (S3);
- in a two-asset channel with one asset's token made to revert on transfer, `transfer(assetIndex)` still pays the
  other asset, and `transferAllAssets` reverts as a whole (S4).

Plus: the existing forge suite and the `armada-nitro-e2e` gate still pass on a fresh fixturenet with the allow-list
deployed by the reconciler.

## Out of scope
A governed (mutable) allow-list; new ForceMove apps; the hub's Aave deposit/redeem operations (E11).
