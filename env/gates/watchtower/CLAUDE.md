# env/gates/watchtower/

E15a: a watcher that detects a counterparty's stale force-close challenge and
answers it on-chain with a newer fully signed state, demonstrated against the
fixturenet.

- `watch.ts` (ethers 6) — the watcher. Subscribes to the adjudicator's
  `ChallengeRegistered` events for one channel (filtered on the indexed
  `channelId` topic, so a concurrent challenge on another channel is
  ignored). When the challenge's turn number is lower than the turn number of
  the fully signed state it holds (`$WATCH_STATE_FILE`), it answers on-chain
  with `checkpoint` using that held state. Prints one JSON line and exits:
  `{detected, responded, block, latency_ms, tx_hash}` — `block` is the
  challenge event's block number, `latency_ms` the time from seeing the event
  to the response transaction confirming, `tx_hash` the response transaction
  (empty when `responded` is `false`).
- `helper.ts` — used only by `scenario.sh`. `build <stale|current>` builds a
  fresh two-party demo channel (user = `testAccounts[0]`, hub =
  `testAccounts[1]`), signs state N (turn 12) and state N+1 (turn 13) with
  both keys, and writes `held-state.json` (the state `watch.ts` holds — N+1
  for `stale`, N for `current`) and `challenge.json` (state N, for the
  counterparty's challenge). `challenge` reads `challenge.json` and sends the
  hub's stale challenge. Funding is out of scope (no payout is checked here —
  that is E15b); `challenge`/`checkpoint` only touch ForceMove's channel
  status, not `MultiAssetHolder`'s holdings, so the demo channel need not be
  funded.
- `scenario.sh <stale|current>` — the gate's entry point. Builds the demo
  channel, starts `watch.ts` in the background, triggers the challenge, and
  prints `watch.ts`'s JSON report on stdout. `stale`: the challenge carries
  turn 12 while the watcher holds turn 13, so it answers (`responded: true`).
  `current`: the challenge already carries the turn the watcher holds, so it
  does not answer (`responded: false`).

Runs against the operator-managed fixturenet
(`$MANIFEST_PATH`/`$KEYS_DIR` default to
`~/deployments/armada-fixturenet-e12/data/armada_env`, `$WATCH_RPC` defaults
to `http://127.0.0.1:8545`). The deployment's test-account key files are
root-owned `600` by default (only the env container, running as root, reads
them); `scenario.sh` best-effort `sudo chmod`s them readable so it can run
directly on the host.

`held-state.json`/`challenge.json`/`.watcher-out` are per-run scratch files
(gitignored), not committed state.

E15b adds the payout gate (docs/tasks/E15-watchtower-response.md): a participant holding a newer
co-signed state defeats a stale force-close if its watcher answers within the dispute window, and
loses that advantage if the watcher is off.

- `prepare.ts` — stage 1: real-proof deposit builder (Groth16-proved
  `depositFromNote` unshield), for two channels (one per scenario), run via
  `npx hardhat run` from `/src/armada-poc` (same pattern as
  `env/gates/nitro-e2e/prepare.ts`). Parameterized by `DEPOSIT_AMOUNT_UNITS`
  (base units, the user funds the whole channel).

The on-chain scenario itself is `script/WatchtowerScenario.s.sol` (challenge,
response/settlement, Shield-log payout read); the orchestrator that runs both
scenarios end to end and prints the gate's JSON result is
`stack/scripts/armada-watchtower-e2e.py`. The compose job wrapper is
`stack/compose-jobs/docker-compose-armada-watchtower-e2e.yml` (job name
`armada-watchtower-e2e`).
