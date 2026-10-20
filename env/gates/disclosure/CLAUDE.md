# env/gates/disclosure/

arn-2fd: the selective-disclosure chain-of-custody acceptance
(docs/tasks/16-selective-disclosure.md, hops H1, H2, H4, H5, H6, H7), run
against a fresh fixturenet by the `armada-disclosure-acceptance` laconic-so
job (`stack/compose-jobs/docker-compose-armada-disclosure-acceptance.yml`,
orchestrated by `stack/scripts/armada-disclosure-acceptance-job.py`).

- `prepare.ts` — stage 1, armada-poc's hardhat/lib/sdk toolchain. H1 shields
  150 USDC from a test EOA into a fresh wallet W; H2+H4 builds a real-proof
  `depositFromNote` transaction bound to a fresh channel (same lib/sdk calls
  as `env/gates/nitro-e2e/prepare.ts`, for one channel). Also precomputes a
  second note of the SAME wallet (`npk = Poseidon(masterPublicKey, random)`,
  independent of any value or channel) and its real, wallet-decryptable
  shield ciphertext, so stage 2 can pay the channel's payout into it and
  stage 3 can recognize and spend it. Writes, under `DISCLOSURE_DIR` (default
  `/env/disclosure`): `wallet.json`, `deposits.json`, `payout-shield.json`,
  `package.json` (H1's evidence).
- `finish.ts` — stage 3. Reopens stage 1's SAME engine database (this job's
  one container/shell; no `clearDatabase()`) and reloads wallet W. Confirms
  the conclude transaction's `Shield` event really pays the precomputed npk2
  (H5, checked here rather than assumed), waits for wallet W to recognize the
  note, then unshields it to a second test EOA with a real proof (H6, same
  lib/sdk calls as `env/gates/pool-e2e/pool-e2e.ts`'s step 3). Overwrites
  `DISCLOSURE_DIR/package.json` with every hop's evidence and the summary
  fields (`hops_ok`, `eoa2_usdc_delta`, `eoa_distinct`, `payout_note_owned`).

Stage 2 (H4 fund, H7 co-sign two channel states, H5 conclude) is
`script/DisclosureScenario.s.sol`, not here — it needs `forge`/`vm.ffi`
(the custodian's FROST-signed `execute`), not the hardhat/lib/sdk toolchain
these two files use.

The job's orchestrator (`stack/scripts/armada-disclosure-acceptance-job.py`)
copies `prepare.ts`/`finish.ts` into `/src/armada-poc/scripts/gates/` before
running them via `npx hardhat run --network hub` (same pattern as
`env/gates/nitro-e2e/prepare.ts` / `env/gates/pool-e2e/pool-e2e.ts`), reads
the conclude transaction's hash from `script/DisclosureScenario.s.sol`'s
forge broadcast file, and passes it to `finish.ts` as `CONCLUDE_TX_HASH`.
