# env/gates/pool-spend/

G7b-spend (arn-d62): proves a real `PrivacyPool.transact` spend on the fixturenet
governance stack, decoupled from the crowdfund window / Baal vote (the former
G7a lifecycle binding, now blocked by the crowdfund's real 21-day window).
Driven by `scripts/check_pool_spend.sh` (outside this directory, so it alone
names the deployment/host paths and the docker/RPC discovery).

`pool-spend.ts` is a new step for the vendored `lib/armada-poc` submodule.
The runner copies it into the submodule's `scripts/` directory at run time
(never commits it there, so the submodule's pinned commit stays clean) and
invokes it with `npx hardhat run scripts/pool-spend.ts --network hub`,
exactly like `env/gates/nitro-e2e/prepare.ts` and `env/gates/pool-e2e/pool-e2e.ts`
do for their own submodule-side scripts (same `lib/sdk` calls, same engine/prover
setup, same event-decoding-from-the-raw-receipt pattern — independent of the SDK's
own event handling).

Flow: read the pool manifest the governance-stack harness wrote
(`deployments/privacy-pool-hub.json`), shield a note directly into the real
`PrivacyPool` from a funded fixturenet account, wait for the shielded note to
scan into spendable balance, then spend it — `createPrivateTransfer`
(`lib/sdk/transfer.ts`), which plans the spend (which UTXOs to select) and
proves it with a real Groth16 proof, the same `planSpend`/`prove` path the
spec names — and submit the proved `transact()` calldata. Verifies, straight
off the transaction receipt (not the SDK's own bookkeeping): the `Transact`
event (proof accepted on chain, new commitment inserted) and the `Nullified`
event (new nullifier recorded). Writes one JSON result file
(`deployments/pool-spend-result.json`) that the runner cats to stdout as the
acceptance oracle's JSON.
