# E11 Aave and Lido end to end through channels

Depends on: E10, E12 (Lido with all scratch steps). Read `docs/ENVIRONMENT.md` §1–§2 and §6–§8, the "As built" sections
of `docs/tasks/E4-aave.md` and `E5-lido.md`, `src/ArmadaNitroAdjudicator.sol`, `src/nitro/` (multi-asset outcomes,
`deposit`), `script/FixturenetScenario.s.sol`, `env/gates/nitro-e2e/prepare.ts`, and the armada-laconic design for the
hub games (the "option 2" yield design: channel asset `waUSDC`; swaps USDC↔`waUSDC` and WETH↔wstETH are state
updates).

## Goal
The environment's Aave and Lido deployments are exercised through the armada-nitro construction the way the hub design
uses them, with real proofs and real contracts. Lido's oracle stays unconfigured: no members, no reports, no price
injection.

## Deliver
A new gate job `armada-assets-e2e` (its own compose job and scripts, reusing `prepare.ts`'s wallet and proof code). It
runs these scenarios in order:

1. **Aave yield is real.**
   - The hub custodian deposits USDC into `waUSDC` (ERC-4626 `deposit`).
   - A second test account supplies USDC to the Aave pool and borrows USDC against it. Our market lists only USDC, with
     LTV 75%; borrowing the supplied asset is allowed. The borrow is enough to raise utilization.
   - Time advances by at least 60 s of real blocks.
   - Checks: `waUSDC.convertToAssets(1e6)` has increased; the Aave pool's USDC `liquidityIndex` has increased. Both are
     read with `cast`.
2. **`waUSDC` as a channel asset.**
   - A user shields `waUSDC` into Armada's pool. It is an ERC-20 and not blocklisted; if the pool rejects it, stop and
     report.
   - The user funds a channel with a real-proof `depositFromNote` of the `waUSDC` note.
   - The hub custodian deposits USDC into the same channel.
   - The channel goes through a cooperative state update that swaps: the user's share is reallocated to USDC and the
     hub's to `waUSDC` (ConsensusApp, both sign).
   - Cooperative close. The user receives a shielded USDC note, and the hub its `waUSDC`, each net of the pool's shield
     fee. This is checked from the pool's `Shield` logs and balances.
3. **wstETH as a channel asset.**
   - A user submits ETH to Lido, wraps the stETH to wstETH (`wstETH.wrap`), shields it, and funds a channel with it
     (real proof).
   - The hub deposits WETH.
   - A swap state update and a force close, through a real challenge window, pay the user WETH and the hub wstETH as
     shielded notes.
   - Checks: `stEthPerToken()` is still `1e18` before and after (the oracle was never reported).
4. **Redeem path.** The hub redeems its `waUSDC` for USDC (ERC-4626 `redeem`). It receives at least the principal
   deposited in scenario 1, measured by the USDC balance change.

If the adjudicator or the Nitro outcome format cannot hold two assets in one channel, stop and report the exact revert
and code path.

## Acceptance (paste output)
On a fresh fixturenet, paste `run-job armada-assets-e2e`, one line per scenario with its on-chain evidence (index
values, balances, note values, transaction hashes).

Discrimination, in scratch copies (revert after); paste each failure line:
- (a) Scenario 1 without the borrow: the "yield increased" check must fail.
- (b) Scenario 2 expecting the user's payout in `waUSDC` instead of USDC: it must fail.
- (c) Scenario 3 with the Lido oracle check expecting `stEthPerToken() > 1e18`: it must fail.

## Out of scope
Liquidations, borrow games in channels (out of scope per the design), Lido withdrawals, Sepolia.
