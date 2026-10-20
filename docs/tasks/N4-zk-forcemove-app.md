# N4: Generic ZK `IForceMoveApp`, verifier wiring, tests with a trivial circuit

Chunk N4 · Family F2 · Points 7 · Route 5090
Depends on: —

Repo: `armada-nitro`. Branch: `integrated`. Work in a new worktree from `origin/integrated`.

Read `src/nitro/interfaces/IForceMoveApp.sol`, `src/nitro/interfaces/INitroTypes.sol`,
`src/nitro/examples/HashLockedSwap.sol` (the appData decode pattern and the
`StrictTurnTaking` call), `src/nitro/libraries/signature-logic/StrictTurnTaking.sol`,
`lib/armada-poc/contracts/privacy-pool/types/PoolTypes.sol` (`G1Point`, `G2Point`,
`SnarkProof`, `VerifyingKey`), and `lib/armada-poc/contracts/privacy-pool/types/SnarkTypes.sol`
(the `Snark` library: `Snark.verify`). `foundry.toml` already remaps `armada/` to
`lib/armada-poc/contracts/`, so `import {Snark} from 'armada/privacy-pool/types/SnarkTypes.sol';`
resolves.

## Goal

Add a generic `IForceMoveApp` that accepts a channel state only when it carries a
valid Groth16 proof, checked against a verifying key fixed at deployment. Wire the
same `Snark` library the Armada pool already uses, so there is one Groth16 checker
in the stack, not two. Prove the wiring end to end with one trivial circuit and a
real proof, not a stub.

## Deliver

- **S1 · `ZkForceMoveApp` contract.** New file `src/nitro/apps/ZkForceMoveApp.sol`.
  - `contract ZkForceMoveApp is IForceMoveApp`. Constructor takes a `VerifyingKey
    memory` and stores it in an immutable-shaped private field (the struct holds a
    dynamic array `ic`, so store it in storage, not as `immutable`; mark the
    contract's set-once intent in a comment, there is no setter).
  - `struct AppData { SnarkProof proof; uint256[] publicInputs; }`. Decode
    `candidate.variablePart.appData` with `abi.decode(appDataBytes, (AppData))`,
    the same pattern `HashLockedSwap.appData` uses.
  - `stateIsSupported(fixedPart, proof, candidate)`: require `proof.length == 1`
    (one prior state), call `StrictTurnTaking.requireValidTurnTaking(fixedPart,
    proof, candidate)` exactly as `HashLockedSwap` does, then decode the
    candidate's `AppData` and call `Snark.verify(verifyingKey, appData.proof,
    appData.publicInputs)`. Return `(true, '')` when it returns `true`. Return
    `(false, 'ZkForceMoveApp: invalid proof')` when it returns `false`. Do not
    catch or swallow a revert from `Snark.verify`; let it propagate.
  - Add a `view` getter `verifyingKey()` returning the stored key, for tests.

- **S2 · The trivial circuit.** Under `test/fixtures/zk-app/trivial/`, add
  `trivial.circom`:
  ```
  pragma circom 2.0.0;
  template Trivial() {
      signal input x;   // private
      signal input y;   // public
      y === x * x;
  }
  component main {public [y]} = Trivial();
  ```
  Compile and prove it with `npx circom2@0.2.23` (circom compiler 2.2.3, confirmed
  installed on this host via `npx`) and `npx snarkjs@0.7.0`:
  1. `circom2 trivial.circom --r1cs --wasm --sym -o build` (adjust the npx
     invocation to the pinned versions above).
  2. Generate a fresh small Powers of Tau, this circuit needs no external
     ceremony: `snarkjs powersoftau new bn128 10 pot10_0000.ptau`, then
     `snarkjs powersoftau contribute pot10_0000.ptau pot10_0001.ptau
     --name="N4 trivial" -e="N4 trivial circuit entropy"`, then
     `snarkjs powersoftau prepare phase2 pot10_0001.ptau pot10_final.ptau`.
  3. `snarkjs groth16 setup build/trivial.r1cs pot10_final.ptau trivial_0000.zkey`,
     then `snarkjs zkey contribute trivial_0000.zkey trivial_final.zkey
     --name="N4 trivial" -e="N4 trivial zkey entropy"`.
  4. `snarkjs zkey export verificationkey trivial_final.zkey
     verification_key.json`.
  5. Witness and proof for `x = 3, y = 9`: write `input.json` `{"x": "3", "y":
     "9"}`, run the generated `build/trivial_js/generate_witness.js` to get
     `witness.wtns`, then `snarkjs groth16 prove trivial_final.zkey witness.wtns
     proof.json public.json`.
  Commit `trivial.circom`, `verification_key.json`, `proof.json` and
  `public.json` under `test/fixtures/zk-app/trivial/`. Do not commit the `.ptau`
  or `.zkey` files; add `test/fixtures/zk-app/trivial/*.ptau` and
  `test/fixtures/zk-app/trivial/*.zkey` to `.gitignore`.

- **S3 · Convert the verifying key and proof to Solidity.** snarkjs's G2
  coordinates are ordered opposite to the `G2Point` struct's `[x0, x1]`
  convention; swap them. This is the same conversion
  `armada-poc/lib/artifacts.ts` (`formatVKeyForSolidity`) and
  `armada-poc/lib/_legacy/prover.ts` already use for the pool's own keys:
  - G1 point `[px, py, 1]` → `G1Point({x: px, y: py})`.
  - G2 point `[[a0, a1], [b0, b1], [1, 0]]` → `G2Point({x: [a1, a0], y: [b1,
    b0]})`.
  - `verifyingKey.alpha1` from `vk_alpha_1`, `.beta2` from `vk_beta_2`, `.gamma2`
    from `vk_gamma_2`, `.delta2` from `vk_delta_2`, `.ic` from `IC` (array of
    G1 points, length 2 for this circuit: one constant term plus one public
    input `y`).
  - Proof `pi_a` → `SnarkProof.a` (G1, no swap). `pi_b` → `SnarkProof.b` (G2,
    swap as above). `pi_c` → `SnarkProof.c` (G1, no swap).
  Write a small Solidity test helper, `test/helpers/ZkAppFixture.sol`, with a
  `library` function `loadTrivialVerifyingKey()` and `loadTrivialProof()` that
  read the four committed JSON files with `vm.readFile` and `vm.parseJson*`
  cheatcodes and return the already-swapped `VerifyingKey` and `SnarkProof`
  structs. Follow `test/helpers/ArmadaNotes.sol`'s use of `vm.readFile` and
  `vm.parseJsonBytes` as the house style for JSON fixture loading.

- **S4 · Tests.** New file `test/ZkForceMoveApp.t.sol`.
  - Deploy `ZkForceMoveApp` with the loaded verifying key.
  - A test that builds a `FixedPart`/`RecoveredVariablePart[]` proof array and
    `RecoveredVariablePart` candidate with `appData` encoding the loaded real
    proof and `publicInputs = [9]` (the trivial circuit's public `y`), signed by
    both participants per `StrictTurnTaking`, and asserts `stateIsSupported`
    returns `(true, '')`.
  - A test with the same candidate but `publicInputs = [10]` (wrong value) and
    asserts `stateIsSupported` returns `(false, 'ZkForceMoveApp: invalid proof')`.
  - A test with a structurally mangled proof (flip one bit of `proof.a.x`) and
    asserts the same failure path, not a revert.
  - A test that `proof.length != 1` reverts (inherited from
    `StrictTurnTaking`/the `require`).

Keep the existing conventions: one `require`/custom-error message per check,
no silent catch of a revert, `SPDX-License-Identifier: MIT` and `pragma
solidity 0.8.17` headers matching every other file under `src/nitro/`.

## Acceptance (paste output)

`forge test --match-path test/ZkForceMoveApp.t.sol -vv` output, with:
- the valid-proof test passing;
- the wrong-public-input test and the mangled-proof test failing before this
  task (no `ZkForceMoveApp` exists, so these tests cannot even compile before
  S1) and passing after;
- the `proof.length != 1` revert test passing.

Plus: the existing `forge test` suite still passes (no asset, pool or
adjudicator file was touched).

## Out of scope

The hidden-balance ledger circuit (N5). The game template (N6). Wiring
`ZkForceMoveApp` as a channel's `appDefinition` in a deployed adjudicator
scenario — that is N5/N6 and the later F2 gate. A governed or upgradeable
verifying key.
