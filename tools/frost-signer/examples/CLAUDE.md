# tools/frost-signer/examples

`gen_forge_fixture.rs`: standalone fixture generator for `test/FrostSigner.t.sol`.
Deliberately NOT a subcommand of the `frost-signer` CLI (the tool's own `--help`
surface stays limited to `keygen`/`sign`; see `tools/frost-signer/src/CLAUDE.md`).

Runs the crate's own `keygen_into` + `sign_shares` for each 2-of-3 share pair over
a fixed 32-byte message, then writes the group key and each pair's `(R, z)` to a
JSON fixture so the Solidity tests can call the exact on-chain verifier
(`FROST.verifySignature`) HubCustodian uses, without duplicating any crypto in
Solidity or Rust:

```
cargo run --manifest-path tools/frost-signer/Cargo.toml \
  --example gen_forge_fixture -- test/fixtures/frost-signer-fixture.json
```

`tools/frost-signer/scripts/forge_signature_checks.sh` regenerates the fixture
before every `forge test` run, so the fixture always reflects the tool's current
behavior rather than a stale checked-in signature.
