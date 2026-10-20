Chunk N1a · Family F4 · Points 8 · Route 5090
Depends on: P2 (see "P2 interface this chunk assumes" below)

Depends on: N1a has no armada-nitro chunk dependency. It needs P2's `preimageOf` and
`transactOwned` entry points in armada-poc, which chunk P2 does not yet have a brief for.
Read `src/nitro/MultiAssetHolder.sol`, `src/ArmadaNitroAdjudicator.sol`, `src/armada/IArmadaPool.sol`,
`test/ArmadaNitroAdjudicator.t.sol`, `test/helpers/ArmadaFixture.sol`, `test/helpers/ArmadaNotes.sol`,
and the armada-laconic lab book
`labbook/2026-10-18-contract-owned-notes-and-zk-channel-apps.md` §3 decisions 9 and 11.

Repo: `armada-nitro`. Branch: `integrated` (work in a `task/N1a` branch cut from `integrated`, per
`docs/ENVIRONMENT.md` §8).

## P2 interface this chunk assumes

Chunk P2 (armada-poc, not yet briefed) must add this surface to the pool. State these as the
contract P2 must meet. If the real P2 interface differs, stop and report the difference instead
of guessing.

1. `function preimageOf(bytes32 commitment) external view returns (CommitmentPreimage memory);`
   A public preimage registry. The pool stores a commitment's `CommitmentPreimage` at the same
   transaction that creates the commitment. A caller reads a note's `token` and `value` from the
   commitment alone, with no off-chain index. This matches lab book decision 3 and 11: "the
   creator publishes the preimage in the creating transaction" and the adjudicator "verifies it
   against the proof's output commitment before it credits anything".
2. `function transactOwned(Transaction[] calldata transactions) external;`
   Spends a note whose `npk` is derived from `msg.sender`, with no EdDSA signature. The pool
   checks `msg.sender == owner` instead (lab book decision 2: "the pool authorizes a
   contract-owned spend by `msg.sender == owner`"). It is callable only by the owning contract.
   One output of the same transaction may mint a fresh contract-owned commitment with `npk`
   derived from a different `owner` address (so one call can both spend the adjudicator's
   existing note and credit its replacement).

Both functions stay inside `IArmadaPool`, the subset interface this repo pins
(`src/armada/IArmadaPool.sol`'s header comment).

## Goal
`MultiAssetHolder`'s `holdings` stop being raw token-unit balances held by the adjudicator
contract. They become references to one Armada pool commitment per `(asset, channelId)`, so a
channel's collateral is, at every point, a note inside the pool (lab book decision 9: "the
adjudicator owns its channel collateral as notes, so the collateral never leaves the pool").

## Deliver
- **S1 · Storage.** Replace `mapping(address => mapping(bytes32 => uint256)) public holdings;`
  with `mapping(address => mapping(bytes32 => bytes32)) public holdings;`, where the value is the
  live commitment for that asset and channel (`bytes32(0)` means no collateral). Keep
  `holdingsLock` unchanged.
- **S2 · Holdings-value helper.** Add
  `function heldValue(address asset, bytes32 channelId) public view returns (uint256)`. It returns
  `0` for an empty commitment, else `pool.preimageOf(holdings[asset][channelId]).value`. Every
  caller that today reads `holdings[asset][channelId]` as an amount (the `expectedHeld` checks in
  `deposit`/`depositFromNote`, the `_apply_transfer_checks` read of `initialAssetHoldings`) reads
  `heldValue` instead.
- **S3 · Base `deposit` is removed.** Delete `IMultiAssetHolder.deposit` from `MultiAssetHolder`
  and its override in `ArmadaNitroAdjudicator`. A channel is funded only through
  `depositFromNote` (N2), because a raw ERC-20 transfer in can never become a pool commitment
  without a proof. Update `IMultiAssetHolder` to drop `deposit` from its interface.
- **S4 · Events.** `Deposited(channelId, asset, held)` and `AllocationUpdated(channelId, asset,
  initialHoldings, newHoldings)` keep their current signatures; `held`/`initialHoldings`/
  `newHoldings` are now the output of `heldValue`, not a direct storage read.

Keep existing conventions: `SafeERC20` stays where raw transfers still occur in this file (none,
after S3); `SafeCast` for the pool's `uint120` values; an event for every holdings change.

## Acceptance (paste output)
`forge test --match-contract MultiAssetHolderCommitmentTest` output for these tests, new in
`test/MultiAssetHolderCommitment.t.sol`, each failing on the commit before this task (compile
failure or wrong type counts as failing) and passing after:
- `heldValue` on an empty `(asset, channelId)` returns `0`;
- `heldValue` on a `(asset, channelId)` with a commitment set by a test helper (a mock
  `preimageOf` returning a fixed `CommitmentPreimage`) returns that preimage's `value`;
- the inherited `IMultiAssetHolder.deposit` selector no longer exists on `ArmadaNitroAdjudicator`
  (a `vm.expectRevert` low-level call to the old 4-byte selector fails: not a revert, a missing
  function).

Plus: `forge build` succeeds with S3's interface change, and the existing `forge test` suite in
`test/ArmadaNitroAdjudicator.t.sol` still compiles (N1b and N2a update the bodies that call the
old `holdings` type; S1 alone breaks their compilation, which this chunk's Acceptance does not
require to pass — name any test file left non-compiling in the report).

## Husband review
Audit-critical. Check:
- `heldValue` never trusts a value the pool did not attest: it always reads `preimageOf`, never a
  cached or passed-in amount.
- No code path sets `holdings[asset][channelId]` to a commitment whose preimage the adjudicator
  has not itself verified (N1b, N2a own the write paths; this chunk only changes the read/storage
  shape).
- `heldValue`'s `0`-for-empty-commitment branch cannot be confused with a real `0`-value note; the
  pool never mints a `0`-value commitment (name an [INFERENCE] if this is not checked in P2).

## Out of scope
`transfer`, `reclaim`, and payout logic (N1b); `depositFromNote` (N2a); payout as a spend (N2b).
