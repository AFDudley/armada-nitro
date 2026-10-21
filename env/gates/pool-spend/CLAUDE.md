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
(`deployments/privacy-pool-hub.json`), fund the payer with hub-chain native (a
fresh fixturenet account starts at 0; the deployer tops it up, since both the
shield and the transact pay gas), shield a note directly into the real
`PrivacyPool`, wait for the shielded note to scan into spendable balance, then
spend it — `createPrivateTransfer` (`lib/sdk/transfer.ts`), which plans the
spend (which UTXOs to select, `planSpend`) and proves it with a real Groth16
proof (`prove`) — the exact path the spec names.

**Submission note (why this gate does not use `createPrivateTransfer`'s
`contractTransaction`/`submitTransaction`):** the vendored
`@railgun-community/engine` package ships a compiled ABI for `transact()`
whose `BoundParams` has the upstream Railgun protocol's original seven fields.
armada-poc's `PrivacyPool` extends `BoundParams` with two P2a fields
(`ownerField`, `publicOutputs` — see `contracts/privacy-pool/types/PoolTypes.sol`),
so the deployed contract's calldata decode is stricter than what the engine's
stale ABI encodes; submitting through the engine's own contract instance
produces calldata the real contract rejects outright (an empty-data revert,
before any pool logic runs — confirmed with `debug_traceTransaction`: no
nested calls, ~67k gas, i.e. a decode-time failure, not a proof or gas
problem). This gate instead builds the `Transaction` struct for the real,
currently-deployed ABI (via hardhat's own `ethers.getContractAt("PrivacyPool",
...)`) and calls `privacyPool.connect(payer).transact([...])` directly,
carrying over the engine's real proof/nullifiers/commitments/boundParams
unchanged and filling the two added P2a fields for this plain (non-owned)
transfer: `ownerField: ethers.ZeroHash`, `publicOutputs: []`. Same real proof,
same real pool, correct encoding.

Verifies, straight off the transaction receipt (not the SDK's own
bookkeeping): the `Transact` event (proof accepted on chain, new commitment
inserted) and the `Nullified` event (new nullifier recorded). Writes one JSON
result file (`deployments/pool-spend-result.json`) that the runner cats to
stdout as the acceptance oracle's JSON.
