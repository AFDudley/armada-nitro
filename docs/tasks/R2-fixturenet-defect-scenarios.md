Chunk R2 · Family F4 · Route 5090
Depends on: arn-690 (closed; the adjudicator is under EIP-170 and deploys)

Read `~/code/git_puller/repos/armada-laconic/.scratch/rewrite-B/departures-found.md`,
`ArmadaLean/Adjudicator/Safety.lean` on `AFDudley/armada-lean` branch `adjudicator-model-v4`,
`stack/compose-jobs/docker-compose-armada-disclosure.yml`,
`stack/scripts/armada-disclosure-acceptance.py`, `env/reconciler/modules/armada.py` (the
`testingMode()` guard).

Repo: `armada-nitro`. Branch: `integrated` (work in a `task/R2-*` branch cut from `integrated`).

## Goal

Today's `ArmadaNitroAdjudicator` departs from its own design in six confirmed ways
(`departures-found.md`). Each scenario below runs on the real fixturenet, against the
real, audited pool verifier, with `testingMode()` off (the reconciler's own guard,
`env/reconciler/modules/armada.py:214-216`, refuses to proceed otherwise). No scenario
runs with `VERIFICATION_BYPASS` or any test-only bypass. Each scenario asserts the
CORRECT behavior a Lean theorem states, so it fails on today's contract and must pass
only once the adjudicator rewrite (a later chunk) lands. A scenario's own acceptance is
that it runs and reports its result, not that it passes today.

## Scenarios

Each scenario stands up or restores the fixturenet from the warm snapshot
(`stack/scripts/fixturenet-new`, `stack/scripts/fixturenet-base-build` never called from a
job), runs a `stack/compose-jobs/` job via `run-job` (never a direct host read of the
deployment's own data directory — gates and runners reach the fixturenet only via `run-job`
and RPC, `gate-no-host-deployment-access`/`job-no-host-deployment-path`), and tears the
fixturenet down on exit with a guarded `laconic-so deployment stop --delete-volumes` then a
guarded `rm -rf` (`: "${DEP:?}"`). No scenario is part of the commit-boundary gate
(`.pre-commit-config.yaml`): each is a standalone, by-hand or by-schedule run, since every
one is expected RED until the rewrite lands.

### (a) Payout succeeds: `payout_can_happen`

Fund a channel with a real-proof `depositFromNote`, conclude it (unanimous signatures,
`conclude`), then `transfer` a nonzero allocation to a recipient. Assert the payout call
does not revert and the recipient's note (`commitment(destination, asset, amount)`) is
live in the pool afterward (`PrivacyPool.isLive`/`preimageOf`, checked by `cast call`
against the fixturenet RPC).

Lean theorem: `payout_can_happen` (`Safety.lean` §D). Fails today on departure item 6
(zero proof): `PoolSpend.mintOwnedCommitments` submits a hard-coded zero Groth16 proof to
`transactOwned`; `PrivacyPool.verifyOwned` rejects it under real verification (confirmed:
it only works today with `testingMode` on), so `transfer`'s payout call reverts.

### (b) A deposit keeps the value in the pool: `notedValue_conserved` (deposit case)

Record the pool's total token balance (not `notedValue` directly — the fixturenet proof
observes the real ERC-20 `balanceOf` the pool contract holds, the on-chain fact
`notedValue` is a model of), fund a channel with a real-proof `depositFromNote`, then
re-read the balance. Assert the pool's token balance does not fall.

Lean theorem: `notedValue_conserved` (`Safety.lean` §C), the deposit instance. Fails today
on departure item 1 (deposit leaves the pool): `depositFromNote` requires
`UnshieldType.NORMAL` (`ArmadaNitroAdjudicator.sol:99`), and `TransactModule._transferTokenOut`
(`:406-424`) pays real ERC-20 OUT of the pool to the adjudicator — an unshield, not a
contract-owned spend. The resulting commitment is never inserted as a leaf
(`_accumulateAndNullify`, `:388-399`), so even the holding this creates can never be spent.

### (c) A reclaim leaves the pool's total note value unchanged: `notedValue_conserved` (reclaim case)

Conclude a source channel holding a guarantee allocation and its target, then `reclaim`
the guarantee. Assert the pool's total token balance for the reclaimed asset is the same
before and after the `reclaim` call.

Lean theorem: `notedValue_conserved` (`Safety.lean` §C), the reclaim instance; also
`reclaim_can_happen` (§D) for the call succeeding at all. Fails today on departure item 2
(reclaim creates value): `_settleReclaimExit` (`ArmadaNitroAdjudicator.sol:192-206`) calls
`PoolSpend.settleReclaim` (`:203-227`), which mints `priorHeld + guaranteeAmount` for the
target from one input of `priorHeld` — nothing debits the source.

### (d) The bulk path reverts: `bulk_paths_never_succeed`

Conclude a channel, then call `transferAllAssets` on it. Assert the call reverts.

Lean theorem: `bulk_paths_never_succeed` (`Safety.lean` §E). Fails today on departure item
5/8 (N3 absent): neither `transferAllAssets` nor `concludeAndTransferAllAssets` is
overridden, so both inherited calls succeed — and per the stage-A confirmation, item 8,
the bulk path mints real spendable notes to every payee with no debit anywhere in the
pool (`PoolSpend.mintPayoutCommitmentsNoChannel`, `nullifiers := []`), pure value
creation.

## Structure

Each scenario is its own `stack/compose-jobs/docker-compose-R2-<name>.yml` job (mirroring
`docker-compose-armada-disclosure.yml`'s shape: `cerc/armada-nitro-env:${ARMADA_IMAGE_TAG}`,
reads the deployment's manifest from the mounted `armada_env` volume, resolves RPC via the
compose service name, prints exactly one JSON result line) and its own
`stack/scripts/verify-r2-<name>.py` driver (mirroring `armada-disclosure-acceptance.py`'s
shape: stand up or restore from the warm snapshot with a run-unique deployment name, run
the job via `run-job`, read its JSON result back, guarded teardown on exit, print exactly
one JSON line itself). Each driver reuses `env/gates/nitro-e2e/prepare.ts`'s wallet + Groth16
prover code for every real proof a scenario needs (shield, `depositFromNote`, the owned
spend `transactOwned` a payout/reclaim calls through) — no scenario authors its own proving
path.

## Acceptance

Each scenario's own acceptance is that it runs end to end on the fixturenet (stand-up or
warm restore, the job, teardown) and reports PASS or FAIL for the one assertion above, with
the real revert reason or balance numbers recorded when it fails. Today, every scenario is
expected to report FAIL, citing the departure item it exercises. Once the adjudicator
rewrite lands, re-running the same scenario, unchanged, is the rewrite's own acceptance
proof for that behavior.

## Chunking

Four chunks, one per scenario (`armada-laconic/engineering/chunk-rules.md`), each at or
under 9 points:

1. (a) payout succeeds — real-proof deposit, conclude, transfer, live-note check. ~7 points.
2. (b) deposit conserves pool balance — real-proof deposit, balance before/after. ~5 points.
3. (c) reclaim conserves pool balance — source + target conclude, reclaim, balance
   before/after. ~7 points.
4. (d) bulk path reverts — conclude, `transferAllAssets`, revert check. ~4 points.
