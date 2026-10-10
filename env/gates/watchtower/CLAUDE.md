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
- `scenario.sh <stale|current>` — the gate's entry point. Delegates to
  `scripts/run-armada-watchtower-scenario.sh` (outside this directory, so it
  alone names the deployment path), which runs the `armada-watchtower-scenario`
  laconic-so job and prints the watcher's JSON report on stdout. Inside the
  job, `helper.ts build`/`watch.ts`/`helper.ts challenge` run exactly as
  described above, reading the manifest and keys from `/env`. `stale`: the
  challenge carries turn 12 while the watcher holds turn 13, so it answers
  (`responded: true`). `current`: the challenge already carries the turn the
  watcher holds, so it does not answer (`responded: false`).

Runs against the operator-managed fixturenet via the `armada-watchtower-scenario`
laconic-so job (`scenario.sh` invokes the job through a helper in `scripts/`).
The job mounts the `armada_env` volume at `/env`, so the manifest and the
test-account keys are read from `/env` (not a host path), with no host access
to the deployment's key files. The job runs with host networking, so
`$WATCH_RPC` (default `http://127.0.0.1:8545`) resolves to geth's host-published
port.

`held-state.json`/`challenge.json`/`.watcher-out` are per-run scratch files
written inside the job's container (gitignored on the off chance anything
ever runs these scripts on the host directly), not committed state.
