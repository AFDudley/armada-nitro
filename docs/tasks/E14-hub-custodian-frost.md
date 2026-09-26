# E14 Hub custodian with real threshold signing

Depends on: E10. Read `src/HubCustodian.sol` (`operationHash`, `execute`, `authorizeDelegate`, `revokeDelegate`,
`rotateGroupKey`, `isActiveDelegate`, `isValidSignature`, `revocationDelay`), `lib/frost-secp256k1-evm`, and
`tools/frost-fixture/src/main.rs` (2-of-3 fixture from the Rust `frost-secp256k1-evm` 3.0.0 crate). Also read how
`script/FixturenetScenario.s.sol` sets up the hub today (`setUpHub`, `_hubExecute`): it uses a single fixed scalar.

## Goal
The hub custodian on the fixturenet is controlled by a real 2-of-3 FROST group from end to end: key generation,
signing rounds, delegate authorization, a channel operation signed by the delegate, revocation with its delay, and group
key rotation. No single party holds the group scalar.

## Deliver
- `tools/frost-signer` (Rust, same pinned crate as `frost-fixture`): a CLI that
  - runs a trusted-dealer or DKG key generation for 3 participants, threshold 2, writing one key-share file per
    participant and the group public key (X, Y);
  - produces a FROST signature for a given 32-byte message from any 2 of the 3 share files, running both rounds;
  - never writes the group scalar.
- The custodian is deployed with the group key from this tool. The fixturenet target takes the group key as parameters;
  update `env/targets/fixturenet.json` and `armada_nitro.py` to take it from a generated key file in the state dir.
- A gate job `armada-custodian-e2e` that:
  1. has signers {1,3} authorize a delegate via `execute(authorizeDelegate)` over `operationHash`;
  2. has the delegate sign a channel state (EIP-1271 through `isValidSignature`), and runs a cooperative close funded by
     a real-proof deposit;
  3. has signers {2,3} schedule `revokeDelegate`. The delegate remains valid until `revocationDelay` passes, then
     `isActiveDelegate` is false and a state signed by it is rejected;
  4. has signers {1,2} `rotateGroupKey` to a new group, and a signature by the old group then fails.

## Acceptance (paste output)
Paste the job output, with each step's transaction hash and check.

Discrimination; paste each failure line:
- (a) A signature from a single share (1 of 3) is rejected by `execute`.
- (b) Replaying step 1's signed operation fails (nonce).
- (c) A state signed by the revoked delegate after the delay is rejected.
- (d) A signature over a different `operationHash` (wrong target) is rejected.

## Out of scope
Networked DKG among separate machines; hub business logic.
