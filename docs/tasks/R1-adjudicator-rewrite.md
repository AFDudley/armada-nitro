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

- Logic moves out of `ArmadaNitroAdjudicator` into external libraries with `public` or `external`
  functions, linked at deploy time. `internal` library functions inline into the caller and do not
  reduce the caller's size (Solidity docs, `libraries.rst`, "the EVM... delegate call... library
  with only internal functions results in the code of the library being added to the calling
  contract"). Candidate split, by current function (`src/ArmadaNitroAdjudicator.sol`):
  - a commitment library: `isAsset`, `heldValue`, `depositBinding`, `_hashCommitment`,
    `_notePreimage`, `_singleton`.
  - a deposit library: `depositFromNote`.
  - a payout/exit library: `_executeSingleAssetExit`, `_settleTransferExit`,
    `_mintTransferPayout`, `_mintPayoutCommitmentsNoChannel`, `_settleReclaimExit`,
    `_mintOwnedCommitments`.
  Splitting into separate contracts is allowed where it gives a cleaner design (ethereum.org,
  "Downsizing contracts"), but the worker chooses the final library/contract boundary. No proxy.
- Every deployed contract (every contract a deploy script deploys, not a test harness) is at or
  below 24,576 bytes runtime (EIP-170). The brief's acceptance records the measured size and
  margin of each deployed contract after the rewrite, from `forge build --sizes`.
- The deploy script (`script/*.s.sol` that deploys `ArmadaNitroAdjudicator`) links the libraries
  at deploy time, the way `forge create --libraries` or a `vm.etch`/library-address pattern
  requires. No deploy script carries an unlinked library placeholder into production.
- Storage: a library that writes adjudicator storage (holdings, channel status) takes the storage
  reference as an argument. A library function runs by `DELEGATECALL` against the caller's storage;
  it cannot read or write its own storage layout.

## Test carryover from N1a-N3

The N1a-N3 test suite (`test/ArmadaNitroAdjudicator.t.sol` and its fixtures) is the behavior
contract for the rewrite. Every test that passes on `integrated` today passes unchanged after the
rewrite (same names, same assertions) unless the test calls a removed inherited-bulk-path
function, in which case it is replaced by the N3 revert-message test.

## arn-7c4 mutant misses to close

arn-7c4 (N3) found these mutation-test misses against `src/ArmadaNitroAdjudicator.sol` on
`integrated` (`.exophial/logs/arn-7c4.gate.log`). Each rewrite chunk that carries the mutated line
closes its miss with a strengthened test or names another test that already kills it:

- offset 2549 (`heldValue`, the `commitment == 0` check): 1/17 mutants missed against
  `test_concludeAndTransferAllAssets_finalizesAndLeavesHoldingsUntouched`.
- offset 2921 (constructor, `configuredAssets[...] = true`): 1/3 mutants missed against
  `test_transferAllAssets_revertsWithUseTransferMessage`.
- offsets 11666, 11738, 11843, 12171, 12743 (`_mintTransferPayout`): 5/29 mutants missed against
  `test_perAssetTransfer_paysEachAssetOnFinalizedChannel`. For each offset, if the mutant is
  equivalent only for the fixture's values (for example `>` to `>=` with no zero-amount
  allocation), add a fixture case that tells them apart (a zero-amount allocation), then assert
  on it.

arn-7c4's predecessor noted "one more offset" beyond these 7 in its handoff. Re-running the gate's
mutation step against the rewrite branch is the authoritative count; do not assume 7 is final
without that re-run.

## Chunking

Split the rewrite into chunks of 9 points or fewer (`armada-laconic/engineering/chunk-rules.md`).
Proposed split, each a separate `exophial intake` filing once this brief merges:

1. Commitment library extraction (`isAsset`, `heldValue`, `depositBinding`, `_hashCommitment`,
   `_notePreimage`, `_singleton`), linked at deploy, with the heldValue mutant (offset 2549)
   closed. ~6 points.
2. Deposit library extraction (`depositFromNote`), with the constructor mutant (offset 2921)
   closed. ~5 points.
3. Payout/exit library extraction (`_executeSingleAssetExit`, `_settleTransferExit`,
   `_mintTransferPayout`, `_mintPayoutCommitmentsNoChannel`, `_settleReclaimExit`,
   `_mintOwnedCommitments`), with the five `_mintTransferPayout` mutants (offsets 11666, 11738,
   11843, 12171, 12743) closed. ~9 points.
4. Deploy script library linking, plus the `forge build --sizes` acceptance record for every
   deployed contract. ~4 points.

## Acceptance

- `forge build --sizes` shows every contract a deploy script deploys at or below 24,576 bytes
  runtime, with the margin recorded in this file or the chunk's spec.
- The full `test/ArmadaNitroAdjudicator.t.sol` suite passes unchanged in behavior.
- The deploy script runs against a local anvil with libraries linked and does not revert.
- The mutation-gated tests re-run against the rewrite branch catch the 7 (or more, per the
  re-run) offsets listed above.
- arn-1ea closes when this set merges.
