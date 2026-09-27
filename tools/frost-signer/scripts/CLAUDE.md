# tools/frost-signer/scripts

The six acceptance-oracle entrypoints named in
`contracts/specs/derived-arn-e98.spec.json`'s `declared_new_entrypoints`. Each
script is self-contained bash: resolves the repo root from its own location,
`cargo build`s the `frost-signer` binary once, and prints one line of JSON to
stdout with the field(s) the spec's `acceptance_tests` observe via `stdout_json`.
None depend on network access or deploy anything.

- `keygen_output_check.sh` — keygen into a fresh dir; `share_file_count`,
  `pubkey_has_x`, `pubkey_has_y`, `total_file_count` (c1–c3).
- `sign_pairs_check.sh` — signs the same message with each of {1,2}/{1,3}/{2,3};
  `signatures_printed_count` (c4).
- `single_share_check.sh` — signs with one share; exits with the tool's own
  (non-zero) exit code; `error_mentions_threshold` (c6). No `set -e`: it must
  observe a deliberate non-zero exit, not abort on it.
- `dependency_version_check.sh` — `cargo metadata` for the resolved
  `frost-secp256k1-evm` version; `resolved_version` (c9).
- `cli_surface_check.sh` — greps `--help` (main, keygen, sign) for network/deploy
  flags; `network_flag_found`, `deploy_flag_found` (c10, c11).
- `forge_signature_checks.sh` — regenerates `test/fixtures/frost-signer-fixture.json`
  via `../examples/gen_forge_fixture.rs`, runs `forge test --match-contract
  FrostSignerTest --json`, and reports how many pair/tamper tests matched and
  passed (c5, c7).
