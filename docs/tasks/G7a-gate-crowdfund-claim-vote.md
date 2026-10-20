
# Chunk G7a · Family F3 · Points 5 · Route 5090

Depends on: G3, G4, G5, G6.
Handoff row moved: `notes/handoff-2026-10-20.md` §0.4, row "F3 governance", chunk G7
(split into G7a and G7b; the labbook's 10-point G7 exceeds the 9-point 5090 cap in
`.scratch/rewrite-evidence/ESTIMATION.md` §2, so it is split here).

Repo: `armada-poc`, gate extension in `armada-nitro`. Branch: `armada-poc` `integrated`
(`60a2f05`) with G1–G6 merged; `armada-nitro` `env/gates/` on its own `integrated`
(`55939ef`).

Read first:
- `armada-nitro/docs/ENVIRONMENT.md` §7, "Gates": the `armada-env-verify` and
  `armada-nitro-e2e` gate shapes this chunk extends, not replaces
  (`.scratch/rewrite-evidence/CHUNK-RULES.md` rule 3: "a new gate chunk is an extension of
  these gates").
- `armada-laconic/labbook/2026-10-18-treasury-governance-baal-safe-shielded.md` §4, the
  G7 check, and §3 decisions 1, 12, 20.
- `contracts/crowdfund/ArmadaCrowdfund.sol:356` (`commit`), `:569` (`claim`) — G7a's
  first two steps.
- `contracts/governance/ArmadaToken.sol`'s `ERC20Votes` inheritance (`:6,12`) and Baal's
  vote-counting call (`labbook/2026-10-18…` §2: "Baal calls `getPastVotes` with a
  timestamp") — G7a's third step.

## Goal

On the fixturenet, one scripted run commits USDC to the crowdfund (G5's shielded-proceeds
path), claims ARM shares, and casts one Baal vote with that ARM's voting power — proving
the first half of the full lifecycle the labbook's G7 check names.

## Deliver

- **S1 · Fixturenet scenario script.** A new script (match the existing
  `armada-nitro-e2e` scenario's language and structure — read
  `armada-nitro/script/LocalScenario.s.sol` first) that: deploys or reuses the
  fixturenet's G1–G6 contracts; has one funded test account call `commit` (G5's existing
  `ArmadaCrowdfund.sol:356`); advances time past `windowEnd`; calls `finalize` (confirms
  G5's shielded-proceeds note lands at the Safe, not a plain balance); has the account
  call `claim` to receive ARM; delegates and casts one Baal vote on a trivial Signaling-
  shaped proposal (or Baal's equivalent minimal proposal type — confirm the exact call
  from the vendored Baal source G2 added).
- **S2 · Gate wiring.** Add this scenario as a new step inside the existing
  `armada-nitro-e2e` gate directory (`armada-nitro/env/gates/nitro-e2e/`) or as a sibling
  gate directory, per CHUNK-RULES rule 3 ("a new step in `pool-e2e`, or a new gate
  directory beside them"). Name it so G7b's continuation (spend, ragequit) runs as the
  next step of the same job, not a separate fixturenet build.
- **S3 · Read state after S1**, not simulated state: pull the ARM balance, the Safe's
  pool-owned note, and the Baal vote tally from the live fixturenet chain after the script
  runs, the same way `armada-nitro-e2e`'s existing checks read chain state and `Shield`
  logs (`docs/ENVIRONMENT.md` §7, "It then runs a cooperative close ... verifies payouts
  from chain state and from the pool's `Shield` logs").

## Acceptance (paste output)

A fixturenet run of the extended gate showing:
1. the crowdfund proceeds reach the Safe as a shielded note, not a public-address balance
   (G5's own test re-verified on a real chain, not a unit-test double);
2. the claimant holds ARM and the Safe's threshold and owner are unchanged (still Baal
   only, per G2);
3. the Baal vote registers with the claimant's ARM voting power.

This gate run failing before G7a exists (no such scenario script runs today) and passing
once S1–S3 are wired.

## Husband review

Confirm step S1 runs against the real fixturenet contracts from G1–G6, not a stand-in
mock of Baal or the Safe.

## Out of scope

Spend and ragequit (G7b). A captured-majority adversarial test (G7b's scope per the G7
check: "a run where a captured majority blocks an exit ... must fail").
