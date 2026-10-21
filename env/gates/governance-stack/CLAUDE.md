# env/gates/governance-stack/

G7-deploy (arn-2be): stands up the full G1–G6 Baal/Safe governance stack from
scratch on a fixturenet, against the real contracts, and records a manifest.
Driven by `scripts/check_governance_stack.sh` (outside this directory, so it
alone names the deployment/host paths).

These three TypeScript files are new/patched steps for the vendored
`lib/armada-poc` submodule. The runner copies each into the submodule's
`scripts/` directory at run time (never commits them there, so the
submodule's pinned commit stays clean) and invokes it with
`npx hardhat run scripts/<name>.ts --network hub`, exactly like
`env/gates/nitro-e2e/prepare.ts` does for its own submodule-side script:

- `deploy_crowdfund.ts` — the PoC's own `scripts/deploy_crowdfund.ts`,
  patched so the Multicall3 `anvil_setCode` etch degrades to a warning
  instead of failing the whole deploy on a real geth fixturenet (which has
  no such debug RPC method; Anvil does).
- `deploy_hedgey_lockup.ts` — deploys the vendored Hedgey `TokenLockupPlans`
  (the G5 team lockup) and records it, the ARM token and the Safe in
  `deployments/hedgey-lockup-hub.json`.
- `governance-stack.ts` — the G7 finalizer. Reads back the five wiring facts
  from live chain state (`safe_owner_is_baal`, `safe_threshold`,
  `arm_allowlist_ok`, `ragequit_wired`, `crowdfund_treasury_is_safe`), writes
  `deployments/governance-stack-hub.json` (every one of the seven contract
  addresses, the wiring, the shaman roles, the ARM allowlist and the
  ragequit burn authority), and emits one `DEPLOY_RESULT_JSON=...` line that
  the runner parses as the acceptance oracle's JSON.

The deploy order the runner drives (G1–G6, then this chunk's additions):
`deploy_cctp_v3` → `deploy_privacy_pool` → `deploy_governance` (Safe + ARM +
RevenueLock) → `summon-baal-safe` (Baal, ShieldedRagequit, loot token;
`docs/tasks/G2-baal-safe-summon.md` in the submodule) → `deploy_crowdfund`
(treasury = the Safe) → `deploy_revenue_lock_cohort` → `deploy_hedgey_lockup`
→ `governance-stack` (this directory's finalizer).
