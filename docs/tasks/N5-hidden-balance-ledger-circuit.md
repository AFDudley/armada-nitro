# N5: Hidden-balance ledger circuit, vectors, ceremony, integration with N4

Chunk N5 · Family F2 · Points 9 · Route Sonnet (circom on the 27B model is
unmeasured risk; this chunk starts on Sonnet, per `ESTIMATION.md` §4)
Depends on: N4

This chunk touches two repos. Slices S1–S4 change `armada-circuits`. Slice S5
changes `armada-nitro`.

- `armada-circuits`: branch `integrated` on the `fork` remote
  (`https://github.com/AFDudley/armada-circuits.git`), starting commit
  `80d8552`. Work in a new worktree from `fork/integrated`.
- `armada-nitro`: branch `integrated`. Work in a new worktree from
  `origin/integrated`.

Read, in `armada-circuits`: `src/operations/Transact.circom` (the Poseidon
commitment and range-check conventions), `src/lib/merkle.circom`,
`src/main/main_1x1.circom` (the entry-point pattern), `scripts/compile.sh`,
`scripts/setup-dev.sh` (the dev Powers-of-Tau and per-circuit zkey pipeline),
`docs/DIFFERENTIAL_TEST_VECTORS.md`. Read, in `armada-nitro`:
`src/apps/ZkForceMoveApp.sol` (new Armada apps live under `src/apps/`, not
`src/nitro/`, which is vendored go-nitro excluded from every pre-commit hook)
and `test/ZkForceMoveApp.t.sol` (both land
in N4; if they do not exist yet in your worktree, stop and report — N5 depends
on N4), `src/nitro/interfaces/INitroTypes.sol`.

## Goal

A circuit that proves a valid hidden-balance move between two channel
participants — the new balances conserve the old total and the new state
commits to them — without revealing either party's balance. Wire it through
N4's `ZkForceMoveApp` so a real channel can finalize on a hidden-balance state.

## Deliver (armada-circuits)

- **S1 · `Ledger` circuit.** New file `src/operations/Ledger.circom`:
  - Public inputs: `prevCommitment`, `nextCommitment`.
  - Private witness: `balance0Prev`, `balance1Prev`, `balance0Next`,
    `balance1Next`, `saltPrev`, `saltNext`.
  - `prevCommitment === Poseidon(balance0Prev, balance1Prev, saltPrev)`.
  - `nextCommitment === Poseidon(balance0Next, balance1Next, saltNext)`.
  - Conservation: `balance0Prev + balance1Prev === balance0Next +
    balance1Next`. This is the only rule the circuit enforces; it says nothing
    about which party's balance changed or by how much — any individual game
    circuit (N6) narrows that further.
  - Range checks on all four balances with `Num2Bits(120)`, the same bound
    `Transact.circom` uses, for the same reason (prevent modular-arithmetic
    wraparound).
  - Use `include "../../node_modules/circomlib/circuits/poseidon.circom"` and
    `bitify.circom`, matching `Transact.circom`'s include paths.
  - New entry point `src/main/main_ledger.circom`:
    `component main {public [prevCommitment, nextCommitment]} = Ledger();`.
    Do not add `ledger` to `scripts/compile.sh`'s `SHAPES` array — that array
    is keyed by `(nullifiers, commitments)` for the Armada pool's shapes, and
    `Ledger` is not a pool shape. Compile it with its own command, recorded in
    S3 below.

- **S2 · Dev ceremony.** Reuse `scripts/setup-dev.sh`'s existing
  `build/ptau/pot17_final.ptau` if it is already generated (power 17 covers
  any circuit under 131,072 constraints; `Ledger` has on the order of a few
  hundred). If it does not exist yet in your worktree, generate it with the
  same two commands `setup-dev.sh` uses (`snarkjs powersoftau new bn128 17
  …` piped `armada-dev-entropy`, then `contribute … --name="dev"` piped
  `armada-contribution-entropy`, then `prepare phase2`). Then, following
  `setup-dev.sh`'s per-shape block exactly (`snarkjs groth16 setup`, `zkey
  contribute --name="dev"` piped `armada-zkey-contribution`, `zkey export
  verificationkey`), produce `build/ledger/final.zkey` and
  `build/ledger/vkey.json`. This is explicitly the **unsafe dev ceremony**
  `setup-dev.sh` already warns about, not the production 1-of-N Phase-2 MPC
  (ADR-0003 D3.2); a production ceremony for `Ledger` is a separate,
  operational task, not part of this chunk.

- **S3 · Build script.** Add `scripts/compile-ledger.sh`, mirroring
  `scripts/compile.sh`'s single-shape body: compile `main_ledger.circom` with
  `circom2 --r1cs --wasm --sym -o build/ledger --O1`. Call it from a new
  target appended to `scripts/setup-dev.sh` (one more `if`/echo block after
  the existing shape loop) so `npm run setup:dev` still produces every
  artifact in one run. Do not change the existing shape loop.

- **S4 · Test vectors.** `Ledger` has no third-party reference implementation,
  unlike `Transact` (which differential-tests against Railgun). Its vectors
  are self-generated: for each case below, compute the witness, run
  `snarkjs groth16 fullprove`, and record the inputs, public signals and proof
  as a fixture under `tests/fixtures/ledger/`, following the field layout
  `tests/fixtures/generated/*.json` already uses (private witness, public
  signals, proof, metadata). Cases:
  1. **Valid move.** `balance0Prev=100, balance1Prev=50` →
     `balance0Next=70, balance1Next=80` (30 moves from party 0 to party 1).
     Proof must verify.
  2. **Conservation violated.** Same `Prev` values, `balance0Next=70,
     balance1Next=90` (20 created from nothing). Witness generation must fail
     the `===` constraint (`circom` witness calculator throws); record the
     error, not a proof.
  3. **Commitment mismatch.** Valid balances but `saltNext` does not match the
     salt used to compute `nextCommitment` in the public input; same failure
     mode as case 2.
  Add a new `## Ledger (hidden-balance channel move)` section to
  `docs/DIFFERENTIAL_TEST_VECTORS.md`, in the same style as the existing
  `## Shield` and `## Simple Transfer` sections, describing the three cases
  and pointing at `tests/fixtures/ledger/`. State plainly that this is a
  generated-vector section, not a differential-test section, because no
  reference implementation exists for this circuit.
  Add `tests/ledger-test.js`, parallel to `tests/diff-test.js`, that replays
  case 1's fixture through `snarkjs groth16 verify` against
  `build/ledger/vkey.json` and asserts it passes, and asserts cases 2 and 3
  fail witness generation. Wire it into `scripts/test.sh` in place of the
  `# Placeholder` comment there.

## Deliver (armada-nitro)

- **S5 · Integration with N4.** `ZkForceMoveApp` (N4) checks a proof against a
  flat `uint256[] publicInputs` with no notion of state continuity across
  moves. `Ledger`'s public inputs are `[prevCommitment, nextCommitment]`, and
  a channel needs `prevCommitment` of the candidate state to equal
  `nextCommitment` of the immediately preceding (proven) state, or a party
  could finalize on a valid-looking move that does not chain from the actual
  prior state. Add `src/apps/LedgerForceMoveApp.sol`:
  - `contract LedgerForceMoveApp is ZkForceMoveApp`, same constructor
    (verifying key for the `Ledger` circuit, converted from
    `armada-circuits`'s `build/ledger/vkey.json` using the same G1/G2
    conversion N4's S3 documents).
  - Override `stateIsSupported` to additionally decode `proof[0]`'s appData
    (the prior, already-supported state) as the same `AppData` shape, and
    require `candidate`'s `AppData.publicInputs[0]` (its `prevCommitment`)
    equals `proof[0]`'s `AppData.publicInputs[1]` (its `nextCommitment`),
    then call `super.stateIsSupported(fixedPart, proof, candidate)` for the
    Groth16 check itself. Revert with `'LedgerForceMoveApp: commitment chain
    broken'` when the equality fails.
  - Copy the converted verifying key from `build/ledger/vkey.json` as a
    committed fixture, `test/fixtures/zk-app/ledger/vkey.json`, plus the three
    vector fixtures from `armada-circuits`'s `tests/fixtures/ledger/` (proof
    and public signals only, not the private witness) as
    `test/fixtures/zk-app/ledger/{valid-move,insufficient-balance}.json`
    (the third, commitment-mismatch, case never reaches a proof — skip it
    here, its witness-generation failure is covered by armada-circuits's own
    test).
  - New test `test/LedgerForceMoveApp.t.sol`: deploy
    `LedgerForceMoveApp` with the converted key; a two-move test (move 1's
    `nextCommitment` feeds move 2's `prevCommitment`) where move 2 is the
    `candidate` and move 1 is `proof[0]`, asserting `stateIsSupported`
    returns `(true, '')`; a test where `proof[0]`'s `nextCommitment` is
    changed by one bit, asserting the revert message above.

## Acceptance (paste output)

`armada-circuits`:
- `bash scripts/compile-ledger.sh` output, showing `build/ledger/main_ledger.r1cs`
  produced.
- `bash scripts/setup-dev.sh` output for the new ledger block, showing
  `build/ledger/final.zkey` and `build/ledger/vkey.json` produced.
- `node tests/ledger-test.js` output: case 1 verifies, cases 2 and 3 fail
  witness generation. These three assertions fail before this task (the file
  does not exist) and pass after.
- `npm run lint:circom` output, clean.

`armada-nitro`:
- `forge test --match-path test/LedgerForceMoveApp.t.sol -vv` output: both
  tests fail before this task (the file and contract do not exist) and pass
  after.
- The existing `forge test` suite, including N4's `ZkForceMoveApp.t.sol`,
  still passes.

## Husband review

Audit-critical. The husband checks, before merge:
- Conservation is the only rule `Ledger` enforces (no circuit path lets
  `balance0Next + balance1Next` exceed `balance0Prev + balance1Prev`), and the
  120-bit range checks are present on all four balance signals, matching
  `Transact.circom`'s rationale against modular wraparound.
- `prevCommitment`/`nextCommitment` are the only public signals; no private
  balance or salt leaks through a public input or an unconstrained signal.
- The G1/G2 conversion in `LedgerForceMoveApp`'s committed `vkey.json` matches
  N4's documented swap exactly (spot check one G2 coordinate pair against
  `build/ledger/vkey.json`'s `vk_beta_2`).
- The commitment-chain check in S5 compares the correct indices
  (`candidate.publicInputs[0]` against `proof[0].publicInputs[1]`) and cannot
  be bypassed by a channel with `proof.length != 1` (inherited from N4's
  `require`).
- The dev ceremony (S2) is clearly marked unsafe-for-production in every file
  it touches, so it is never mistaken for the real Phase-2 MPC.

## Out of scope

A production Phase-2 MPC ceremony for `Ledger` (operational, not code). A
game-specific narrowing of which party's balance may move and by how much —
that is N6. More than two participants: the commitment hashes every balance and one salt with one circomlib
`Poseidon(n)`, defined for at most 16 inputs (circomlib 2.0.5 `poseidon.circom`, state width up to 17), so one hash
covers at most 15 parties; more parties need a tree of hashes (armada-laconic `engineering/14-shielded-games-over-nitro.md`).
A third, on-chain-verified
commitment-mismatch test case (armada-circuits's witness-generation failure
already covers it).
