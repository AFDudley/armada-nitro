# N6: Game template circuit and one example game

Chunk N6 · Family F2 · Points 7 · Route 5090
Depends on: N4

This chunk does not depend on N5. Do not import or assume N5's files exist;
write N6 self-contained, even where its shape resembles N5's ledger circuit.
A later pass may factor the shared conservation logic out; that is not this
chunk.

This chunk touches two repos. Slices S1–S3 change `armada-circuits`. Slice
S4 changes `armada-nitro`.

- `armada-circuits`: branch `integrated` on the `fork` remote
  (`https://github.com/AFDudley/armada-circuits.git`), starting commit
  `80d8552`. Work in a new worktree from `fork/integrated`.
- `armada-nitro`: branch `integrated`. Work in a new worktree from
  `origin/integrated`.

Read, in `armada-circuits`: `src/operations/Transact.circom` (Poseidon
commitment and 120-bit range-check conventions), `src/main/main_1x1.circom`
(entry-point pattern), `scripts/compile.sh`, `scripts/setup-dev.sh`. Read, in
`armada-nitro`: `src/apps/ZkForceMoveApp.sol` (new Armada apps live under
`src/apps/`, not `src/nitro/`, which is vendored go-nitro excluded from every
pre-commit hook) and
`test/ZkForceMoveApp.t.sol` (both land in N4; if missing in your worktree,
stop and report — N6 depends on N4), `src/nitro/interfaces/INitroTypes.sol`.

## Goal

A reusable circom template for a two-party, balance-conserving game move —
the shared shape every ZK channel game needs (old balances commit, new
balances commit, total is conserved) — and one concrete game built on it, so
the template is proven by a real instance, not left abstract.

## Deliver (armada-circuits)

- **S1 · `GameTemplate`.** New file `src/lib/game-template.circom`:
  ```
  pragma circom 2.0.0;
  include "../../node_modules/circomlib/circuits/poseidon.circom";
  include "../../node_modules/circomlib/circuits/bitify.circom";

  // Reusable two-party balance-conservation core for a ZK game move.
  // A game circuit includes this file and instantiates GameTemplate() to
  // get the commitment and conservation checks, then adds its own
  // move-validity constraints and wires its own computed balances to
  // balance0Next / balance1Next.
  template GameTemplate() {
      signal input prevCommitment;   // public
      signal input nextCommitment;   // public
      signal input balance0Prev;
      signal input balance1Prev;
      signal input balance0Next;
      signal input balance1Next;
      signal input saltPrev;
      signal input saltNext;

      component prevHash = Poseidon(3);
      prevHash.inputs[0] <== balance0Prev;
      prevHash.inputs[1] <== balance1Prev;
      prevHash.inputs[2] <== saltPrev;
      prevCommitment === prevHash.out;

      component nextHash = Poseidon(3);
      nextHash.inputs[0] <== balance0Next;
      nextHash.inputs[1] <== balance1Next;
      nextHash.inputs[2] <== saltNext;
      nextCommitment === nextHash.out;

      balance0Prev + balance1Prev === balance0Next + balance1Next;

      component r0 = Num2Bits(120); r0.in <== balance0Prev;
      component r1 = Num2Bits(120); r1.in <== balance1Prev;
      component r2 = Num2Bits(120); r2.in <== balance0Next;
      component r3 = Num2Bits(120); r3.in <== balance1Next;
  }
  ```

- **S2 · `MatchingPennies`, the example game.** New file
  `src/operations/MatchingPennies.circom`. Two players each commit a private
  bit (`move0`, `move1`); if the bits match, player 0 wins `stake` from
  player 1; if they differ, player 1 wins `stake` from player 0. This is the
  smallest well-defined zero-sum two-player game, so it exercises the
  template with one real payoff rule.
  ```
  pragma circom 2.0.0;
  include "../lib/game-template.circom";

  template MatchingPennies() {
      signal input prevCommitment;   // public
      signal input nextCommitment;   // public
      signal input stake;            // public
      signal input balance0Prev;
      signal input balance1Prev;
      signal input saltPrev;
      signal input saltNext;
      signal input move0;            // private, must be 0 or 1
      signal input move1;            // private, must be 0 or 1

      move0 * (move0 - 1) === 0;
      move1 * (move1 - 1) === 0;

      signal diff;
      diff <== move0 - move1;
      signal diffSq;
      diffSq <== diff * diff;
      signal match;                  // 1 if move0 == move1, else 0
      match <== 1 - diffSq;

      signal sign;                   // +1 if player 0 wins, -1 if player 1 wins
      sign <== 2 * match - 1;

      signal delta;
      delta <== stake * sign;

      signal balance0Next;
      signal balance1Next;
      balance0Next <== balance0Prev + delta;
      balance1Next <== balance1Prev - delta;

      component core = GameTemplate();
      core.prevCommitment <== prevCommitment;
      core.nextCommitment <== nextCommitment;
      core.balance0Prev <== balance0Prev;
      core.balance1Prev <== balance1Prev;
      core.balance0Next <== balance0Next;
      core.balance1Next <== balance1Next;
      core.saltPrev <== saltPrev;
      core.saltNext <== saltNext;
  }

  component main {public [prevCommitment, nextCommitment, stake]} = MatchingPennies();
  ```
  New entry point is this file itself (circom allows `component main` in the
  operation file directly; follow this file's own structure, do not add a
  separate `src/main/main_matching_pennies.circom` — `Transact`'s split
  between `src/operations/` and `src/main/` exists because `Transact` is
  parameterized by `(N, M)` and needs one entry point per shape;
  `MatchingPennies` has no shape parameter, so one file suffices).
  Do not add `matching-pennies` to `scripts/compile.sh`'s `SHAPES` array —
  that array is keyed by the Armada pool's `(nullifiers, commitments)` pool
  shapes, not this circuit.

- **S3 · Build, dev key, and tests.** Add `scripts/compile-game.sh`,
  mirroring `scripts/compile.sh`'s single-shape body: compile
  `src/operations/MatchingPennies.circom` with `circom2 --r1cs --wasm --sym
  -o build/matching-pennies --O1`. Reuse `build/ptau/pot17_final.ptau` if it
  already exists in your worktree (generated by `scripts/setup-dev.sh`,
  power 17 covers this circuit's few hundred constraints); otherwise
  generate it with `setup-dev.sh`'s exact two-command sequence (`powersoftau
  new bn128 17` piped `armada-dev-entropy`, `contribute --name="dev"` piped
  `armada-contribution-entropy`, `prepare phase2`). Produce
  `build/matching-pennies/final.zkey` and `build/matching-pennies/vkey.json`
  with the same `groth16 setup` / `zkey contribute --name="dev"` piped
  `armada-zkey-contribution` / `zkey export verificationkey` commands
  `setup-dev.sh` uses for every other shape. This is the unsafe dev key, not
  a production ceremony — N6 carries no ceremony deliverable.
  Add `tests/matching-pennies-test.js`: generate a witness and proof for two
  cases (player 0 wins: `move0=move1=1`; player 1 wins: `move0=0, move1=1`),
  verify both with `snarkjs groth16 verify` against
  `build/matching-pennies/vkey.json`, and assert a third case with
  `move0 = 2` (not a bit) fails witness generation. Commit the two winning
  fixtures under `tests/fixtures/matching-pennies/{p0-wins,p1-wins}.json`
  (same field layout as `tests/fixtures/generated/*.json`). Wire the script
  into `scripts/test.sh` beside N5's `tests/ledger-test.js` call if present,
  else in place of the `# Placeholder` comment.

## Deliver (armada-nitro)

- **S4 · Integration with N4.** New file
  `src/apps/MatchingPenniesForceMoveApp.sol`:
  - `contract MatchingPenniesForceMoveApp is ZkForceMoveApp`, same
    constructor shape as N4 (a `VerifyingKey`, converted from
    `armada-circuits`'s `build/matching-pennies/vkey.json` using the G1/G2
    swap N4 documents).
  - `AppData.publicInputs` for this app is `[prevCommitment, nextCommitment,
    stake]` (3 entries, matching `MatchingPennies`'s public signals in
    declaration order).
  - Override `stateIsSupported` to additionally require that `stake` (index
    2) is identical between `candidate` and `proof[0]` — the stake is fixed
    for the life of a channel, only the balances move — and that
    `candidate.publicInputs[0]` (`prevCommitment`) equals
    `proof[0].publicInputs[1]` (`nextCommitment`), then call
    `super.stateIsSupported`. Revert with
    `'MatchingPenniesForceMoveApp: stake changed'` or
    `'MatchingPenniesForceMoveApp: commitment chain broken'` respectively.
  - Copy the converted verifying key as `test/fixtures/zk-app/matching-pennies/vkey.json`
    and the two winning-case fixtures from `armada-circuits`'s
    `tests/fixtures/matching-pennies/` (proof and public signals only) as
    `test/fixtures/zk-app/matching-pennies/{p0-wins,p1-wins}.json`.
  - New test `test/MatchingPenniesForceMoveApp.t.sol`: deploy with the
    converted key; a two-move test chaining the p0-wins fixture's
    `nextCommitment` into a second move as `prevCommitment`, asserting
    `stateIsSupported` returns `(true, '')`; one test with a changed `stake`
    in the candidate, asserting the `stake changed` revert; one test with a
    broken commitment chain, asserting the `commitment chain broken` revert.

Keep the existing conventions: `SPDX-License-Identifier: MIT` and `pragma
solidity 0.8.17` headers, one `require`/revert message per check, `vm.readFile`
/ `vm.parseJson*` for fixture loading (`test/helpers/ArmadaNotes.sol`'s
style).

## Acceptance (paste output)

`armada-circuits`:
- `bash scripts/compile-game.sh` output, showing
  `build/matching-pennies/main.r1cs` (or `MatchingPennies.r1cs`, name per
  the actual circom output) produced.
- The dev-key commands' output, showing `build/matching-pennies/final.zkey`
  and `vkey.json` produced.
- `node tests/matching-pennies-test.js` output: both winning cases verify,
  the non-bit case fails witness generation. All three assertions fail
  before this task (file does not exist) and pass after.
- `npm run lint:circom` output, clean.

`armada-nitro`:
- `forge test --match-path test/MatchingPenniesForceMoveApp.t.sol -vv`
  output: all three tests fail before this task (file and contract do not
  exist) and pass after.
- The existing `forge test` suite, including N4's `ZkForceMoveApp.t.sol`,
  still passes.

## Husband review

Not on the audit-critical list (P1, P2, N1, N2, G3). Standard review: the
`GameTemplate` conservation check and 120-bit range checks are present and
unconditional; `MatchingPennies`'s bit constraints (`move0 * (move0 - 1) ===
0`) actually bind `move0`/`move1` to `{0, 1}`, not merely assigned as such;
the stake and commitment-chain checks in `MatchingPenniesForceMoveApp` use
the correct public-input indices.

## Out of scope

A production ceremony for `MatchingPennies` (none is owed by this chunk). A
second example game. Any change to N5's `Ledger` circuit or
`LedgerForceMoveApp`, or a shared refactor between N5 and N6 — they are
independent chunks and this chunk does not read N5's files.
