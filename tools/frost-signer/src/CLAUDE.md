# tools/frost-signer/src

Core logic (`lib.rs`) and CLI wiring (`main.rs`) for the `frost-signer` binary: a
trusted-dealer 2-of-3 FROST(secp256k1, KECCAK-256) keygen and threshold signing
tool. Uses the same pinned `frost-secp256k1-evm = "=3.0.0"` crate as
`tools/frost-fixture` (see `../Cargo.toml`).

- `lib.rs`: `keygen_into` (writes `share-1`/`share-2`/`share-3` + `group-pubkey.json`,
  never the group secret) and `sign_shares`/`sign_packages` (both FROST rounds +
  aggregate). No I/O beyond file reads/writes for share/pubkey files; no network.
- `main.rs`: `clap`-derived CLI (`keygen --out <dir>`, `sign --shares <a> <b>
  --message <hex32>`). The single-share refusal (naming the 2-of-3 threshold) lives
  here; `sign_packages` also fails naturally via `frost::aggregate`'s own
  `IncorrectNumberOfShares` check below threshold (defense in depth).

Spec: `docs/tasks/E14-hub-custodian-frost.md` (Deliver, frost-signer). Reference
implementation this crate mirrors for the keygen/round1/round2/aggregate flow:
`tools/frost-fixture/src/main.rs`.
