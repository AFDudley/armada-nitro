Chunk N8 · Family F4 · Points 6 · Route 5090
Depends on: N2b, N7, G4

G4 (RevenueLock rewrite on `cumulativeFees`, family F3 governance, `armada-poc`) is not yet
briefed at the time of this writing. This chunk's acceptance needs G4's `RevenueLock` deployed and
reading `cumulativeFees` from the pool. If G4 has not merged when this chunk starts, stop and
report the blocker instead of stubbing RevenueLock.

Read `src/ArmadaNitroAdjudicator.sol` (post-N2b), `env/gates/` (the `CLAUDE.md` and `prepare.ts`
layout of `nitro-e2e` and `watchtower`, as the pattern a new gate job follows),
`docs/ENVIRONMENT.md` §7 ("Gates"), and the armada-laconic lab book
`labbook/2026-10-18-treasury-governance-baal-safe-shielded.md` §3 decisions 15, 22, 23 and §4
("N8 gate").

Repo: `armada-nitro`. Branch: `integrated` (work in a `task/N8` branch cut from `integrated`).

## P2/G4 interface this chunk assumes

- `pool.feeRecipient()` and `pool.cumulativeFees(address asset)` exist (N2b's P2 assumptions 1–2).
- G4's `RevenueLock` exposes a view that reads `cumulativeFees` from the pool directly (not a
  separately reported figure) and a release function whose payable amount is bounded by it
  (governance lab book decision 22: "RevenueLock keeps its purpose but reads `cumulativeFees` from
  the pool ... every unlock corresponds to real USDC that ARM holders own"). If G4 ships a
  different read path, use it and report the difference from this assumption.

## Goal
Prove, on the fixturenet, that a swap fee generated inside an armada-nitro channel reaches
RevenueLock as real, releasable value: the fee is paid as a Safe-owned note, the pool's
`cumulativeFees` increases by exactly that amount, and RevenueLock can release funds bounded by
that increase.

## Deliver
- **S1 · New gate job `armada-swap-fee-e2e`.** Follow `env/gates/nitro-e2e`'s layout: a
  `compose-jobs/docker-compose-armada-swap-fee-e2e.yml`, a `prepare.ts` (reused wallet/proof code
  from `env/gates/nitro-e2e/prepare.ts` and `env/gates/watchtower/prepare.ts`), and a stage-2
  Forge script or TypeScript driver, per whichever of the two existing gates' pattern fits a
  single-stage scenario best (name the choice in the report).
- **S2 · Scenario.** Fund a two-party channel (N2a `depositFromNote`, one asset). Run a cooperative
  state update whose outcome allocates a swap fee to `pool.feeRecipient()` as a `SHIELD`-type
  allocation (N2b). Cooperative close, paying out via `transfer(assetIndex, ...)` (N3).
- **S3 · Checks, each read independently of the SDK, by `cast` or a minimal ABI decode:**
  - the fee output's commitment is recorded by `pool.preimageOf` with `npk == pool.feeRecipient()`
    and the expected value;
  - `pool.cumulativeFees(asset)` increased by exactly the fee amount, read before and after;
  - RevenueLock's release call (G4) pays out, bounded by the post-increase `cumulativeFees` value,
    and reverts if asked to release more than that bound.
- **S4 · Negative case.** The same scenario with the fee allocation's `destination` set to a
  non-`feeRecipient` address: `pool.cumulativeFees(asset)` must not increase. Paste this failure
  line per `docs/ENVIRONMENT.md` §8's discrimination convention.

## Acceptance (paste output)
On a fresh fixturenet, `run-job armada-swap-fee-e2e`, one line per check in S3, with its on-chain
evidence (the fee commitment, the `cumulativeFees` before/after values, the RevenueLock release
transaction hash and amount). Then S4's negative case, pasted separately, showing
`cumulativeFees` unchanged.

## Husband review
Check:
- the gate reads `cumulativeFees` and the RevenueLock bound independently of each other, so a bug
  that always reports "enough" cannot pass unnoticed;
- the negative case (S4) genuinely exercises a fee allocation that is not recognized as fee-tagged,
  not a zero-amount allocation that would be skipped for an unrelated reason;
- the gate does not depend on G4's internal implementation beyond the public `cumulativeFees` read
  and the release call's documented bound.

## Out of scope
G4's own RevenueLock contract and tests (family F3 governance); G7's full
crowdfund→claim→vote→spend→ragequit gate, which this chunk's scenario is a narrower slice of.
