# N6: Game template circuit and one example game

Chunk N6 · Family F2 · Points 9 · Route Sonnet (circom on the 27B model is
unmeasured risk; the circuit slices start on Sonnet, per `ESTIMATION.md` §4)
Depends on: N4

This chunk does not depend on N5. Do not import or assume N5's files exist;
write N6 self-contained, even where its shape resembles N5's ledger circuit.
A later pass may factor the shared conservation logic out; that is not this
chunk.

This chunk touches two repos. Slices S1–S3 change `armada-circuits`. Slice
S4 changes `armada-nitro`. The repo boundary is also the split boundary: if the
combined chunk exceeds 9 points at filing, file the circuit slices (S1–S3,
`armada-circuits`) as one pebble and the app slice (S4, `armada-nitro`) as a
second pebble that depends on it.

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
the template is proven by a real instance, not left abstract. The example game
is Battleship: a turn-based game with persistent hidden state, proven move by
move by the single owner of that state. Each player commits a hidden board; on
each turn the defender proves hit or miss against its own committed board, and
the board stays hidden for the whole game. This is the exact property N4's
Groth16 verifier exists to support, and a hash check cannot replace it:
revealing a cell's preimage would reveal the board. If a player stops answering
and the challenge times out, the app awards the staked pot to the opponent.

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

- **S2 · `Battleship`, the example game.** New file
  `src/operations/Battleship.circom`. The board is a flat `N`-cell grid; each
  cell is `0` (water) or `1` (ship). Use the minimal pedagogical instance
  `N = 9` (a 3×3 grid) and a fixed ship count `SHIPS = 3`; a real board shape
  (contiguous ships, no overlap) is out of scope (see "Out of scope"). The
  defender committed its board once as `Poseidon(boardPacked, boardSalt)`,
  where `boardPacked` packs the `N` cell bits into one field element. On a
  turn, the attacker's shot names a cell `target`; the defender proves the
  public `result` (`1` hit, `0` miss) equals its committed board's cell at
  `target`, without revealing any other cell. A hit moves `stake` from the
  defender (player 1) to the attacker (player 0); a miss moves nothing. The
  balances commit and conserve through `GameTemplate`.

  Public inputs, in declaration order: `prevCommitment`, `nextCommitment`,
  `boardCommitment`, `target`, `result`, `stake`.
  Private witness: `balance0Prev`, `balance1Prev`, `saltPrev`, `saltNext`,
  `cell[N]`, `boardSalt`, `selector[N]`.

  The circuit enforces, each as circom-legal (degree ≤ 2) constraints, with
  intermediate signals where a sum of products is needed (a single `<==` may
  not carry a sum of two or more products):
  1. **Each board cell is a bit:** `cell[i] * (cell[i] - 1) === 0`.
  2. **Fixed ship count** (blocks the empty-board cheat, where a defender with
     no ships always answers "miss"): `sum(cell[i]) === SHIPS`.
  3. **Board commitment binds the hidden board.** Pack the bits:
     `boardPacked === sum(cell[i] * 2**i)` (a linear combination, one signal),
     then `component bc = Poseidon(2); bc.inputs[0] <== boardPacked;
     bc.inputs[1] <== boardSalt; boardCommitment === bc.out;`.
  4. **`selector` is one-hot and points at `target`:**
     `selector[i] * (selector[i] - 1) === 0`, `sum(selector[i]) === 1`, and
     `sum(i * selector[i]) === target`.
  5. **`result` is the committed cell at `target`:** introduce
     `prod[i] <== selector[i] * cell[i]` and a running sum
     `acc[i] <== acc[i-1] + prod[i]`, then `result === acc[N-1]`. `result` is
     then `0` or `1` by construction.
  6. **Payoff.** `balance0Next <== balance0Prev + stake * result;`
     `balance1Next <== balance1Prev - stake * result;`. A hit (`result = 1`)
     moves `stake` from the defender to the attacker; a miss moves nothing.
  7. **`GameTemplate`.** Wire `prevCommitment`, `nextCommitment`, the four
     balances and the two salts into `component core = GameTemplate();` so the
     balance commitments, conservation and 120-bit range checks all apply.

  End the file with the entry point:
  `component main {public [prevCommitment, nextCommitment, boardCommitment, target, result, stake]} = Battleship();`.
  The entry point is this file itself (circom allows `component main` in the
  operation file directly; follow this file's own structure, do not add a
  separate `src/main/main_battleship.circom` — `Transact`'s split between
  `src/operations/` and `src/main/` exists because `Transact` is parameterized
  by `(N, M)` and needs one entry point per shape; `Battleship` has no shape
  parameter, so one file suffices). Do not add `battleship` to
  `scripts/compile.sh`'s `SHAPES` array — that array is keyed by the Armada
  pool's `(nullifiers, commitments)` pool shapes, not this circuit.

- **S3 · Build, dev key, and tests.** Add `scripts/compile-game.sh`,
  mirroring `scripts/compile.sh`'s single-shape body: compile
  `src/operations/Battleship.circom` with `circom2 --r1cs --wasm --sym
  -o build/battleship --O1`. Reuse `build/ptau/pot17_final.ptau` if it
  already exists in your worktree (generated by `scripts/setup-dev.sh`,
  power 17 covers this circuit's few hundred constraints); otherwise
  generate it with `setup-dev.sh`'s exact two-command sequence (`powersoftau
  new bn128 17` piped `armada-dev-entropy`, `contribute --name="dev"` piped
  `armada-contribution-entropy`, `prepare phase2`). Produce
  `build/battleship/final.zkey` and `build/battleship/vkey.json`
  with the same `groth16 setup` / `zkey contribute --name="dev"` piped
  `armada-zkey-contribution` / `zkey export verificationkey` commands
  `setup-dev.sh` uses for every other shape. This is the unsafe dev key, not
  a production ceremony — N6 carries no ceremony deliverable.
  Add `tests/battleship-test.js`: generate a witness and proof for two
  cases — a hit (the defender's board has a ship at `target`, `result = 1`,
  `stake` moves to the attacker) and a miss (no ship at `target`, `result = 0`,
  balances unchanged) — verify both with `snarkjs groth16 verify` against
  `build/battleship/vkey.json`, and assert a third case fails witness
  generation: a lying defender that claims `result = 0` for a `target` cell
  its committed board actually marks as a ship (the `result === acc[N-1]`
  constraint rejects it). Commit the two passing fixtures under
  `tests/fixtures/battleship/{hit,miss}.json` (same field layout as
  `tests/fixtures/generated/*.json`). Wire the script into `scripts/test.sh`
  beside N5's `tests/ledger-test.js` call if present, else in place of the
  `# Placeholder` comment.

## Deliver (armada-nitro)

- **S4 · Integration with N4.** New file
  `src/apps/BattleshipForceMoveApp.sol`:
  - `contract BattleshipForceMoveApp is ZkForceMoveApp`, same
    constructor shape as N4 (a `VerifyingKey`, converted from
    `armada-circuits`'s `build/battleship/vkey.json` using the G1/G2
    swap N4 documents).
  - `AppData.publicInputs` for this app is `[prevCommitment, nextCommitment,
    boardCommitment, target, result, stake]` (6 entries, matching
    `Battleship`'s public signals in declaration order).
  - Override `stateIsSupported` to additionally require, then call
    `super.stateIsSupported` for the Groth16 check itself:
    - `stake` (index 5) is identical between `candidate` and `proof[0]` — the
      stake is fixed for the life of a channel, only the balances move. Revert
      `'BattleshipForceMoveApp: stake changed'`.
    - `boardCommitment` (index 2) is identical between `candidate` and
      `proof[0]` — the defender's board is committed once and never changes.
      Revert `'BattleshipForceMoveApp: board changed'`.
    - `candidate.publicInputs[0]` (`prevCommitment`) equals
      `proof[0].publicInputs[1]` (`nextCommitment`) — the balance-commitment
      chain. Revert `'BattleshipForceMoveApp: commitment chain broken'`.
  - **Timeout awards the opponent.** The app adds no new timeout machinery; it
    relies on the plain Nitro adjudicator. A defender that stops answering a
    shot cannot produce a higher supported state (each state needs a valid
    Groth16 answer the non-answerer will not give). The attacker challenges on
    the last supported state; after `challengeDuration` the channel concludes
    on it, and that state's balances award the pot moved so far to the
    attacker. State this award rule in a file-level comment, and note that the
    escrow that funds the pot (so the award is collectible) is the collateral
    and commitment-outcome machinery of N2/N3, not N6.
  - Copy the converted verifying key as `test/fixtures/zk-app/battleship/vkey.json`
    and the two passing-case fixtures from `armada-circuits`'s
    `tests/fixtures/battleship/` (proof and public signals only) as
    `test/fixtures/zk-app/battleship/{hit,miss}.json`.
  - New test `test/BattleshipForceMoveApp.t.sol`: deploy with the
    converted key; a two-move test chaining the hit fixture's
    `nextCommitment` into a second move as `prevCommitment` (same
    `boardCommitment` and `stake`), asserting `stateIsSupported` returns
    `(true, '')`; one test with a changed `stake` in the candidate, asserting
    the `stake changed` revert; one test with a changed `boardCommitment`,
    asserting the `board changed` revert; one test with a broken commitment
    chain, asserting the `commitment chain broken` revert.

Keep the existing conventions: `pragma solidity 0.8.17`
headers, one `require`/revert message per check, `vm.readFile`
/ `vm.parseJson*` for fixture loading (`test/helpers/ArmadaNotes.sol`'s
style).

## Acceptance (paste output)

`armada-circuits`:
- `bash scripts/compile-game.sh` output, showing
  `build/battleship/Battleship.r1cs` (name per the actual circom output)
  produced.
- The dev-key commands' output, showing `build/battleship/final.zkey`
  and `vkey.json` produced.
- `node tests/battleship-test.js` output: the hit and miss cases verify,
  the lying-defender case fails witness generation. All three assertions fail
  before this task (file does not exist) and pass after.
- `npm run lint:circom` output, clean.

`armada-nitro`:
- `forge test --match-path test/BattleshipForceMoveApp.t.sol -vv`
  output: all four tests fail before this task (file and contract do not
  exist) and pass after.
- The existing `forge test` suite, including N4's `ZkForceMoveApp.t.sol`,
  still passes.

## Husband review

Not on the audit-critical list (P1, P2, N1, N2, G3). Standard review:
- The `GameTemplate` conservation check and 120-bit range checks are present
  and unconditional.
- The board stays hidden: `cell[]` and `boardSalt` are private, and only
  `boardCommitment` (a Poseidon commitment) reaches a public input; no cell
  leaks through a public signal or an unconstrained signal.
- The board is bound: `result` is forced to equal the committed board's cell
  at `target` (`result === acc[N-1]` over `selector[i] * cell[i]`), so a
  defender cannot answer "miss" on a ship cell.
- The `selector` is one-hot and selects exactly `target`.
- `sum(cell) === SHIPS` holds, so an empty board is rejected.
- The stake, board-commitment and balance-commitment-chain checks in
  `BattleshipForceMoveApp` use the correct public-input indices
  (`5`, `2`, and `0` vs `proof[0]`'s `1`).

## Out of scope

A production ceremony for `Battleship` (none is owed by this chunk). A
second example game. Real ship-shape validity (contiguous ships of agreed
lengths, no overlap) — the minimal instance checks only a fixed ship count.
A larger board than the 3×3 pedagogical grid. The escrow/collateral that funds
the timeout award (that is N2/N3). Any change to N5's `Ledger` circuit or
`LedgerForceMoveApp`, or a shared refactor between N5 and N6 — they are
independent chunks and this chunk does not read N5's files.
