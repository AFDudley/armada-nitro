# E15b gate: intermittent prover crash, not reproduced

Lab book entry, 2026-10-07. Pebbles: arn-d76 (E15b, armada-watchtower-e2e), arn-a27 (the gate bug
exophial filed when it parked arn-d76 as NONDETERMINISTIC).

## What happened

exophial's gate for arn-d76 ran twice on the same commit, `a526f8c`:

| Run (2026-10-05, UTC) | Result |
|---|---|
| 07:27–07:31 | FAILED (returncode 1) |
| 07:37–07:43 | PASSED, 6/6 acceptance tests |

A merge collision at 07:37 made exophial retry the integration, which re-ran the gate. Seeing two
different verdicts on one commit, exophial parked the pebble and filed arn-a27.

The failing run's log is gone: both runs write `.exophial/logs/arn-d76.gate.log`, and the passing run
overwrote it (filed as exophial exo-8625).

## What the evidence shows

- **One test died before sending any transaction.** The gate runs all six acceptance tests with no
  early stop, and each test runs the full e2e script. forge's broadcast records in the worktree
  (`broadcast/WatchtowerScenario.s.sol/31337/`) show 5 complete transaction cycles for the failing run
  and 6 for the passing run. The only step before the first transaction is deposit preparation
  (`env/gates/watchtower/prepare.ts`, called by `build_deposits()` in
  `stack/scripts/armada-watchtower-e2e.py`), which runs Groth16 proving.
- **The prover has crashed this way before.** In the worker's own session, at 07:12, a run of
  `prepare.ts` aborted mid-proof with V8's fatal banner and passed on immediate retry:

  ```
  # Fatal error in , line 0
  # unreachable code
  #FailureMessage Object: 0x7a27e57ed180
  ----- Native stack trace -----
  ```

  No stack frames were captured after the header.
- **Ruled out:** chain problems (geth logged steady 2 s blocks and no reorgs, 07:25–07:45), on-chain
  reverts (every broadcast receipt in the window has status 1), channel-ID collisions (channel nonces
  are random per run), and the "expected exactly one payout note" check (a failure there leaves a
  complete broadcast cycle, which the count rules out).
- **Exposure:** each test proves 2 deposits and the gate runs 6 tests, so one gate run means 12
  proofs, with no retry anywhere. One crash anywhere turns the gate red.

The banner is V8's internal abort (`UNREACHABLE()` in a release build), not a WebAssembly trap or a
circom assert. V8 has thousands of assertions that print the same banner, so the message alone
doesn't identify the bug.

## Candidate cause (unconfirmed)

[nodejs/node#66366](https://github.com/nodejs/node/issues/66366) (open, filed 2026-09-28): in V8 13.6
the WebAssembly-to-JavaScript call-wrapper cache became process-wide, and a wrapper being freed by
WebAssembly code GC on one thread can be freed again by another. Fixed upstream in V8 `68210d500a` and
`9b8ca54d5a` (crbug 409379692); not backported to Node 24.x; present in Node 26.

Why it fits: our Node v24.18.0 ships the affected V8, 13.6.233.17. Proving runs WebAssembly that calls
into JavaScript (circom's witness calculator, Railgun's wasm-bindgen modules) while ffjavascript starts
and stops 32 worker threads per proof.

Why it isn't confirmed: the issue's reporter sees a CHECK failure or SIGSEGV, not "unreachable code".
The match rests on the same V8 build and workload, not the same message. A second issue with the same
literal banner, [nodejs/node#51555](https://github.com/nodejs/node/issues/51555) (V8 code-cache
corruption), is unlikely here: nothing in this project uses a V8 code cache.

No matching reports exist in the snarkjs, ffjavascript, wasmcurves, Railgun engine or hardhat trackers.

## Reproduction attempts

All local, without the chain, on kelce (Ryzen 9 7950X, 32 threads, Node v24.18.0):

| Setting | Proofs | Crashes |
|---|---|---|
| Proving only, single-threaded (ffjavascript) | 400 | 0 |
| Proving only, multi-threaded (default, 32 workers) | 3,200 | 0 |
| Multi-threaded, `--no-wasm-code-gc` | 100 | 0 |
| Multi-threaded, Node v22.18.0 | 100 | 0 |
| Synthetic #66366 pattern (fresh processes) | ~240 processes | 0 |

Nothing crashed, so these runs establish neither the cause nor a fix. The harness ran the proving
math (wasmcurves, which doesn't call into JavaScript) but not the witness calculator, which needs
valid Railgun circuit inputs.

## What would settle it

A crashing baseline on the real path: capture valid circuit inputs from one `prepare.ts` run, loop the
full prove on them, witness calculator included, until it crashes, then repeat the loop with
`--no-wasm-code-gc` and on Node 22. Only a drop to zero there would justify a change.

## Decision

No change. arn-a27 is closed as not reproduced, pointing here. arn-d76 is landed by re-running its gate
through `exophial integrate`; if the prover crashes again, the gate fails and we stop rather than
retrying until it passes.
