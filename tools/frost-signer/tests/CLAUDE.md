# tools/frost-signer/tests

Integration tests (`cli.rs`) for the built `frost-signer` binary
(`env!("CARGO_BIN_EXE_frost-signer")`), not just the library:

- keygen writes exactly `share-1`, `share-2`, `share-3`, `group-pubkey.json`,
  and the pubkey file has `x`/`y` and nothing else.
- each of the three 2-of-3 share pairs signs a fixed message and the printed
  signature verifies with `frost_secp256k1_evm`'s own `VerifyingKey::verify`
  (the same crate/verifier `test/FrostSigner.t.sol` checks on-chain) — this is
  the assertion that actually catches a broken round1/round2/aggregate wiring,
  not just "the process exited 0".
- signing with a single share exits non-zero and stderr names the threshold.
- a signature over one message does not verify against a different message.

Run with `cargo test --manifest-path tools/frost-signer/Cargo.toml`.
