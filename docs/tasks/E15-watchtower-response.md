# E15 Challenge response (watchtower behavior)

Depends on: E10. Read `src/nitro/ForceMove.sol` (`challenge`, `checkpoint`, the `ChallengeRegistered` event, turn
number rules), `script/FixturenetScenario.s.sol`, and `docs/tasks/E10-gates-fixes.md`.

## Goal
Show on the fixturenet that a participant who holds a newer supported state defeats a counterparty's force-close with a
stale state, if it answers within the challenge window. Show the loss when it does not answer. This is the contract-level
behavior armada-client's watchtower (P2-06) will automate.

## Deliver
A gate job `armada-watchtower-e2e` with:
- **A watcher script** (`env/gates/watchtower/watch.ts`, ethers 6). It subscribes to the adjudicator's
  `ChallengeRegistered` events for a channel. When a challenge carries a turn number lower than the latest state the
  user holds (fully signed), it answers with `checkpoint` (or a counter-`challenge`, whichever ForceMove requires) using
  that state. It logs the event block, the response transaction and the latency.
- **Scenario A.**
  - A channel is funded with a real-proof deposit.
  - Both parties sign state N, which gives the user more, and later state N+1, which gives the user even more. The hub
    challenges with state N.
  - The watcher answers with N+1 within the window.
  - After finalization, the payout equals N+1's allocation: shielded note values net of the shield fee, from `Shield`
    logs.
- **Scenario B.** The same, with the watcher off. The payout equals state N's allocation. This proves the test
  distinguishes the two outcomes.

## Acceptance (paste output)
Paste the job output for both scenarios: the challenge transaction, the response transaction and its latency, the final
payouts, and the check lines.

Discrimination, in scratch copies (revert after); paste each failure line:
- (a) The watcher answers with a state signed only by the user (not fully supported): the response reverts, and
  scenario A's payout check fails.
- (b) The watcher answers after the window: the response reverts, and the payout equals state N.

## Out of scope
armada-client's watchtower implementation (P2-06), Waku, multiple channels.
