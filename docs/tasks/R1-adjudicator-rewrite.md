Chunk R1 · Family F4 · Route 5090
Depends on: arn-1ea, N1a, N1b, N2a, N2b (behavior already merged into ArmadaNitroAdjudicator.sol
on `integrated`). Supersedes arn-7c4 (N3).

Read `src/ArmadaNitroAdjudicator.sol`, `src/nitro/MultiAssetHolder.sol`,
`src/nitro/NitroAdjudicator.sol`, `test/ArmadaNitroAdjudicator.t.sol`,
`docs/tasks/N1a-multiassetholder-commitment-storage.md`,
`docs/tasks/N1b-multiassetholder-commitment-transfer.md`,
`docs/tasks/N2a-deposit-from-note-as-spend.md`, `docs/tasks/N2b-payout-as-spend.md`,
`docs/tasks/N3-commitment-outcome-finalization.md`.

Repo: `armada-nitro`. Branch: `integrated` (work in a `task/R1-*` branch cut from `integrated`).

## Operator ruling

ArmadaNitroAdjudicator is rewritten, not repaired. `forge build --sizes` on `integrated` measures
its runtime size at 25,558 bytes, 982 bytes over the EIP-170 limit of 24,576 (arn-1ea). No
fixturenet can deploy `armada_nitro` from `integrated` while this holds.

## Behavior (unchanged)

The rewrite keeps every behavior the N1a, N1b, N2a, N2b and N3 briefs establish:

- N1a: holdings store a `bytes32` commitment per asset per channel, not a `uint256` amount.
  `heldValue` reads the commitment's preimage through the pool's `preimageOf`.
  `depositFromNote` spends an owned note through the pool's `transactOwned` and records the
  resulting commitment as the channel's holding.
- N1b: `transfer` and `reclaim` move collateral between a finalized channel's commitment and its
  payees' owned commitments in one `transactOwned` call. The inherited bulk `uint256` arithmetic in
  `MultiAssetHolder` does not run against commitment storage.
- N2a: a deposit is one `transactOwned` spend of an owned note; no raw ERC-20 transfer into the
  adjudicator.
- N2b: a payout is one more output of the same `transactOwned` spend as `transfer`. No fee tag, no
  `cumulativeFees` coupling. There is no protocol fee on a payout.
- N3: the adjudicator finalizes a channel (sets its status to finalized) without the inherited
  `NitroAdjudicator._transferAllAssetsBody` bulk payout path. Every payout routes through
  `MultiAssetHolder.transfer(assetIndex, ...)`, already commitment-aware. `transferAllAssets` and
  `concludeAndTransferAllAssets` revert with a use-`transfer` message instead of running the
  inherited bulk path.

## Structure

This is a rewrite, not a repair. The new code is written against the N1a-N3 behavior and the
carried-over tests, not produced by moving functions out of the current
`src/ArmadaNitroAdjudicator.sol`. The worker may read the old file for reference only; the
must-hold is the behavior and the tests, not the old file's function list.

Logic lives in external libraries with `public` or `external` functions, linked at deploy time.
`internal` library functions inline into the caller and do not reduce the caller's size (Solidity
docs, `libraries.rst`, "the EVM... delegate call... library with only internal functions results
in the code of the library being added to the calling contract"). New components:
  (a) a commitment-holdings library: reads and writes the per-asset, per-channel `bytes32`
      commitment holdings (N1a); `isAsset`, `heldValue` and the preimage/hash helpers the N1a-N3
      behavior needs.
  (b) a pool-spend library: every `transactOwned` call the adjudicator makes — deposit (N2a),
      transfer/payout (N1b, N2b) and reclaim, plus minting owned commitments.
  (c) the new adjudicator contract, built on the upstream `NitroAdjudicator`/`MultiAssetHolder`
      base, using libraries (a) and (b): the N3 finalize-only conclude (sets a channel finalized
      without the inherited bulk payout) and the bulk-path reverts (`transferAllAssets`,
      `concludeAndTransferAllAssets` revert with the use-`transfer` message).
  (d) the deploy script: links libraries (a) and (b) at deploy time and records each deployed
      contract's measured size and margin.
  Splitting into separate contracts beyond (a)-(c) is allowed where it gives a cleaner design
  (ethereum.org, "Downsizing contracts"), but the worker chooses the final boundary within that
  split. No proxy.
- Every deployed contract (every contract a deploy script deploys, not a test harness) is at or
  below 24,576 bytes runtime (EIP-170). The brief's acceptance records the measured size and
  margin of each deployed contract after the rewrite, from `forge build --sizes`.
- The deploy script (`script/*.s.sol` that deploys the new adjudicator contract) links the
  libraries at deploy time, the way `forge create --libraries` or a `vm.etch`/library-address
  pattern requires. No deploy script carries an unlinked library placeholder into production.
- Storage: a library that writes adjudicator storage (holdings, channel status) takes the storage
  reference as an argument. A library function runs by `DELEGATECALL` against the caller's storage;
  it cannot read or write its own storage layout.

## Test carryover from N1a-N3

The N1a-N3 test suite (`test/ArmadaNitroAdjudicator.t.sol` and its fixtures) is the behavior
contract for the rewrite. Every test that passes on `integrated` today passes unchanged in
behavior after the rewrite (same names, same assertions) unless the test calls a removed
inherited-bulk-path function, in which case it is replaced by the N3 revert-message test.

## arn-7c4 mutant misses to close

arn-7c4 (N3) found these mutation-test misses against `src/ArmadaNitroAdjudicator.sol` on
`integrated` (`.exophial/logs/arn-7c4.gate.log`). Each rewrite chunk whose new code covers the
old mutated behavior closes the matching miss with a strengthened test or names another test that
already kills it:

- `heldValue`'s `commitment == 0` check (old offset 2549, component (a)): 1/17 mutants missed
  against `test_concludeAndTransferAllAssets_finalizesAndLeavesHoldingsUntouched`.
- the constructor's `configuredAssets[...] = true` (old offset 2921, component (c)): 1/3 mutants
  missed against `test_transferAllAssets_revertsWithUseTransferMessage`.
- `_mintTransferPayout` (old offsets 11666, 11738, 11843, 12171, 12743, component (b)): 5/29
  mutants missed against `test_perAssetTransfer_paysEachAssetOnFinalizedChannel`. For each one, if
  the mutant is equivalent only for the fixture's values (for example `>` to `>=` with no
  zero-amount allocation), add a fixture case that tells them apart (a zero-amount allocation),
  then assert on it.

arn-7c4's predecessor noted "one more offset" beyond these 7 in its handoff. Re-running the gate's
mutation step against the rewrite branch is the authoritative count; do not assume 7 is final
without that re-run.

## Chunking

One chunk covers components (a), (b) and (c) together, in one branch: the commitment-holdings
library, the pool-spend library, and the new adjudicator contract that uses both. They land
together because the commit-boundary gate (arn-578) runs `forge build --sizes` on the whole
build on every `.sol` commit; a branch that adds a library but leaves the old, oversized
`ArmadaNitroAdjudicator.sol` in place fails that gate on the worker's own first commit, before
any merge attempt. Only a branch that both adds the libraries and replaces the old file passes.
This exceeds the 9-point single-5090 cap (`armada-laconic/engineering/chunk-rules.md` rule 1,
`armada-laconic/engineering/build-plan.md` "Routing"), so it starts on Sonnet rather than
splitting, the same way `armada-laconic/engineering/build-plan.md` routes N1 and N2 (each over 9
points, both marked "Sonnet (audit-critical)").

1. Commitment-holdings library, pool-spend library, new adjudicator contract (components a, b,
   c): the per-asset, per-channel commitment storage read/write, `heldValue`, `isAsset`,
   preimage/hash helpers (a, built against N1a's behavior and tests); every `transactOwned`
   call — deposit (N2a), transfer/payout (N1b, N2b), reclaim, minting owned commitments (b, built
   against N1b/N2a/N2b's behavior and tests); the N3 finalize-only conclude and the bulk-path
   reverts on the upstream base, using libraries (a) and (b) (c, carries N3's behavior and tests,
   arn-7c4 superseded). Closes all 7 confirmed mutant misses: `heldValue` (old offset 2549),
   the constructor (old offset 2921), and the five `_mintTransferPayout` misses (old offsets
   11666, 11738, 11843, 12171, 12743). ~23 points, Sonnet.
2. Deploy script (d): links libraries (a) and (b) at deploy time, plus the `forge build --sizes`
   acceptance record for every deployed contract. Depends on chunk 1. ~4 points, 5090.

## Acceptance

- `forge build --sizes` shows every contract a deploy script deploys at or below 24,576 bytes
  runtime, with the margin recorded in this file or the chunk's spec.
- The full `test/ArmadaNitroAdjudicator.t.sol` suite passes unchanged in behavior.
- The deploy script runs against a local anvil with libraries linked and does not revert.
- The mutation-gated tests re-run against the rewrite branch catch the 7 (or more, per the
  re-run) offsets listed above.
- arn-1ea closes when this set merges.
