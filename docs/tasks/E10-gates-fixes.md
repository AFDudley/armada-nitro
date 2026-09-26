# E10 Gate fixes: our own pool e2e; challenge window enforced

Depends on: E9. Read `docs/ENVIRONMENT.md` §6–§8, `docs/tasks/E7-gates.md`, `stack/compose-jobs/docker-compose-armada-env-verify.yml`,
`env/gates/nitro-e2e/prepare.ts`, `script/FixturenetScenario.s.sol`, `src/nitro/ForceMove.sol` (`challenge`,
`checkpoint`), `src/nitro/NitroAdjudicator.sol` (`transferAllAssets`), and in the image
`/src/armada-poc/scripts/capture/e2e-armada-circuits.ts` (steps 1–3).

## Goal
Both gates are green, and each proves what it claims.

## Deliver
- **`armada-env-verify`, second stage.** Replace the call to Armada's `e2e-armada-circuits.ts` with our own script
  `env/gates/pool-e2e/pool-e2e.ts`. Its step 4 (yield) needs Armada governance, their yield adapter and their mock Aave,
  none of which this environment deploys.
  - The new script uses the same armada-poc `lib/sdk` as `prepare.ts`, from a test account:
    1. shield 10 USDC;
    2. privately transfer 3 USDC to a second wallet;
    3. unshield 1 USDC from the second wallet.
  - Each step uses a real proof. Each step's result is checked on chain, independently of the SDK:
    - the `Shield`, `Transact` and `Unshield` events;
    - the recipient's public USDC balance change, net of the pool's shield and unshield fees, read from
      `shieldFee()`/`unshieldFee()`.
  - The circuit shape of each proof is printed.
- **Challenge window enforced.** In the `armada-nitro-e2e` force-close path, attempt `transferAllAssets` immediately
  after `challenge`, before the window ends. It must revert, and the step prints the revert reason. Then wait out the
  window, and settlement must succeed.

## Acceptance (paste output)
On a fresh fixturenet (E9: no manual steps), paste the output of `run-job armada-env-verify` and `run-job
armada-nitro-e2e`. Both must exit 0.

Discrimination, in scratch copies (revert after); each must make its gate fail, and you paste the failure line:
- (a) `pool-e2e.ts` expects the shield note without subtracting the shield fee. (Unshield is free by Armada's spec,
  `TransactModule._transferTokenOut`, so an unshield-fee mutation would not discriminate.)
- (b) The early settle attempt is removed from the scenario's expected-revert check, i.e. the early settle is expected
  to succeed.
- (c) Run the gate with `CHALLENGE_DURATION=1`. The early-settle step must still see a revert, or you report why the
  one-second window cannot be observed on 2 s slots and pick the smallest duration that can.

## As built
- Unshield is fee-free (`unshieldFee()` is deprecated and always 0); shield fee is inclusive, 50 bps here.
- The early-settle attempt is a plain `call` inside the script, not broadcast, so a revert does not abort `forge
  script --broadcast`.
- Gates spend test-account USDC; each gate job first runs `reconciler --only funding`, which mints only the
  shortfall. Without it, the funding postcondition failed after one run of the gates (account 1 at 80 USDC).

## Out of scope
Aave/Lido assets in channels (E11), the watchtower (E15).
