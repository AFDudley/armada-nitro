# env/gates/nitro-disclosure/

Gate that runs the selective-disclosure hops (H1-H7 of `docs/tasks/16-selective-disclosure.md`)
as real transactions on the fixturenet, records every transaction and event into a disclosure
package, and reports the hop result.

The hop runner (`disclosure.ts`) executes, in order:
- **H1** a test EOA shields USDC into a fresh note (`npk1`).
- **H2 + H4** the note funds a hub channel through `depositFromNote` (a real Groth16 proof).
- **H7** the wallet and the hub co-sign a final channel state (the user EOA key + a fresh hub
  delegate authorized on the `HubCustodian` through one FROST-signed `execute` call).
- **H5** the channel pays a `SHIELD` allocation to a fresh note (`npk2`) of the same wallet.
- **H6** that note is unshielded to a second test EOA.

It writes the disclosure package (statement + every transaction and event) to `$PACKAGE_PATH`
(defaults to `/env/nitro-disclosure/disclosure-package.json`) and prints one JSON line:
`{"hops_ok", "eoa2_usdc_delta", "eoa_distinct", "payout_note_owned", "package_path"}`.

The runner runs inside the `armada-disclosure` laconic-so job
(`stack/compose-jobs/docker-compose-armada-disclosure.yml`), not as a host process -- gates and
runners reach the fixturenet only via `run-job` and geth RPC, never a direct host read of the
deployment's own state directory. The job first does an up-check (pool, `HubCustodian`,
adjudicator respond on the fixturenet RPC), then copies `disclosure.ts` into the image's
`armada-poc/scripts/gates/` and runs it with `npx hardhat run` from `/src/armada-poc`, so its
relative `lib/sdk` imports resolve against the image.

The acceptance harness is `stack/scripts/armada-disclosure-acceptance.py`: it stands up the warm
fixturenet base snapshot (`stack/scripts/fixturenet-new`), runs the job, tears the fixturenet
down (`teardown`), and prints the hop result. The script exits 0 and prints exactly one JSON
line to stdout (all diagnostics go to stderr).

Environment variables the job reads (with defaults):
- `HUB_RPC` (defaults to `http://armada-fixturenet-geth:8545`, the compose service name -- no
  host networking; the job runs on the deployment's own docker network).
- `MANIFEST_PATH` (defaults to `/env/manifest.json`), `PACKAGE_PATH`, `KEYS_DIR`
  (defaults to `/env`), `FROST_SHARES_DIR` (defaults to `/env`), `FROST_SIGNER`
  (defaults to `frost-signer`), `CHALLENGE_DURATION` (defaults to 30s).
