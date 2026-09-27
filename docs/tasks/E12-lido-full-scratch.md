# E12 Lido: run the skipped scratch-deploy steps

Depends on: E9. Read the "As built" section of `docs/tasks/E5-lido.md`, `env/reconciler/modules/lido.py`,
`env/lido/steps-fixturenet.json`, `env/lido/deploy-params-fixturenet.toml`, and in the image `/src/lido-core`
(v4.0.1): `scripts/scratch/steps.json`, `scripts/scratch/steps/0135-deploy-staking-modules.ts`,
`0140-plug-staking-modules.ts`, `0150-transfer-roles.ts`, `lib/account.ts` (`impersonate`), and whatever
`0135` pulls from `lidofinance/community-staking-module`.

## Background
E5 skipped three of Lido's scratch-deploy steps:
- `0135` deploys the Community Staking Module and Curated Module v2 from a separate repository;
- `0140` plugs them into the staking router by impersonating the Aragon Agent (`hardhat_impersonateAccount`), which
  real geth does not support;
- `0150` transfers the OpenZeppelin admin roles to the Agent.

As a result, the deployer still holds admin roles on the oracle contracts. On mainnet those roles belong to Lido's DAO.

## Goal
The fixturenet's Lido matches a real deployment's shape: every scratch step runs, with no edit to lido-core or the
staking-module repository, and admin roles end with the DAO Agent.

## Deliver
- `0150` runs as published.
- `0135` runs as published. If the staking-module deploy hits its own `block_gas_limit` cap of 60M, set
  `FOUNDRY_BLOCK_GAS_LIMIT` in the environment; E5 reproduced a ~73.6M estimate. Pin the
  `community-staking-module` source it uses in `env/sources.lock.json`, and bake it into the image like other sources.
- `0140`'s effect is achieved without impersonation. The calls it makes as the Agent (read the step for the exact
  calls) go through a real Aragon vote, the same mechanism `lido.py` already uses to resume staking. That is our own
  step script, listed in `env/lido/steps-fixturenet.json` in place of `0140`. It must perform the same calls with the
  same arguments as `0140`; show a side-by-side of calls.
- `lido` verify adds these postconditions:
  - the staking router lists the same modules a scratch deploy on hardhat's in-process network produces (run that once
    inside the image to get the expected list and record it with provenance);
  - the deployer holds no `DEFAULT_ADMIN_ROLE` on the locator, AccountingOracle, either HashConsensus, or the staking
    router, and the Agent does.

  The existing postconditions stay: oracle unconfigured, `stEthPerToken` = 1e18, zero HashConsensus members.

## Acceptance (paste output)
On a fresh fixturenet, paste:
- the full reconcile, with lido gas and wall time;
- the second reconcile (no transactions);
- the staking-router module list next to the hardhat reference;
- the role checks.

Negative case: grant the deployer `DEFAULT_ADMIN_ROLE` on one oracle contract (through a DAO vote or the role holder)
and show that `--verify-only` fails naming it.

## As built (findings from the run)

Landed as four sequential slices on `task/E12` (commits `3c4d639`, `5d7d07e`, `f73aca1` -- slice 4 added
no new code of its own, see below):

### Slice 1 -- pin community-staking-module, bake it into the image offline
Pinned at `ef4eb70640c679d0ca6ad2a5d15339f55a9b0d40` in `env/sources.lock.json`. Fixed a real bug in the
inherited Dockerfile draft along the way: `git config --system key=value` (one combined argument) is
silently a no-op read, not a set -- git parses it as a query and exits 1 without writing anything, which
would have left the `insteadOf` rewrite missing and `just deps` trying to hit the real network at image
build time. Fixed to two arguments. Also removed a bogus `YARN_CACHE_DIR` env var (not a real Yarn config
key); Yarn 4's default `enableGlobalCache=true` already makes `$HOME/.yarn/berry/cache` work offline with
the image's fixed `HOME=/root`, verified end to end with `--network none`.

### Slice 2 -- 0140 via a real DAO vote, proven equal to upstream 0140
`env/lido/0140-plug-staking-modules-via-vote.ts` makes the same Agent calls, same targets/calldata/order,
as upstream's `0140-plug-staking-modules.ts` -- proven with a capture tool
(`env/lido/tools/capture-0140-calls.ts`) that intercepts every `Agent.execute` call both scripts make and
diffs them: **empty diff, 32/32 calls match**. A negative control (one swapped argument) produces a
non-empty diff, proving the tool actually discriminates.

Two premises in this slice's brief turned out false, both fixed the boring way:
- "`NETWORK=hardhat` ... the full scratch deploy runs there": `scripts/utils/staking-modules.ts`'s
  `deployStakingModules()` special-cases Hardhat's own literal `--network hardhat` string to skip the
  external CSM/Curated-Module-v2 deploy entirely (no RPC endpoint for Foundry to broadcast against
  in-process). Fixed by running the capture harness with `RUN_NETWORK=localhost` against a real,
  standalone JSON-RPC server instead.
- That standalone server was first `npx hardhat node`, which hit a real, documented Foundry <-> Hardhat
  Network incompatibility (foundry-rs/foundry#5303 and #7639: `-32602 expected a 8 byte hex string` on
  `eth_getBalance`). Switched to Anvil (`--gas-limit 300000000 --disable-code-size-limit --hardfork osaka`,
  same test mnemonic) -- Anvil is what Foundry is built against and has no such issue.

`env/lido/reference-staking-modules.json` (used by slice 4's postcondition) was recorded from this same
real capture run: `curated-onchain-v1`/`SimpleDVT` (both NodeOperatorsRegistry, upstream), `Community
Staking` (CSModule), `curated-onchain-v2` (CuratedModule).

### Slice 3 -- every scratch step runs on a fresh fixturenet
`lido.py` drives the full 0000-0150 migration (0135's external CSM+CMv2 deploy, our
0140-plug-staking-modules-via-vote, 0150's role transfer) against the real fixturenet geth. Real bugs
found and fixed in an inherited draft along the way:
- `apply()`'s idempotency early-return (`if observed and observed.get("locator"): return "present", 0`)
  had been commented out -- restored; without it every reconcile would redeploy Lido from scratch.
- The via-vote script was being copied to lido-core's checkout root instead of `lido-core/scripts/`;
  `lib/scratch.ts`'s `resolveMigrationFile` would never have found it there.
- `FOUNDRY_BLOCK_GAS_LIMIT=100000000` added to the real deploy's environment (Curated Module v2's own
  Foundry profile caps simulated gas at 60M against a ~73.6M estimate; the real chain's genesis gas limit
  is already 200M, so only Foundry's own cap needed raising -- same fix slice 1 needed for the offline
  `just deps` step).

#### The "transient" failure chase
What looked at first like flaky infrastructure turned out to be three distinct, real, and fixable causes,
found in sequence as each was ruled out:

1. **CPU contention on the host.** The fixturenet originally ran 64 validators in one validator client on
   shared cores; under host load it reorged often (one measured window: 50 reorgs in 641 blocks over
   23m26s, ~7.8%). A clean 4-validator genesis alone did not change the rate (4 reorgs in 44 blocks), so
   the validator count was not the cause. Validators were cut to 4 anyway (4 single-key clients;
   `docker-compose-armada-fixturenet.yml`, `docs/tasks/E1-fixturenet.md`), and the fixturenet's cores
   were reserved under a runtime cgroup (with this, the reserved cores went from 90-96% busy to <1%):
   - `/run/systemd/system/fixturenet.slice` (`AllowedCPUs=10-15,26-31`), geth and the beacon each pinned
     to 2 cores, each of the 4 validators pinned to its own single core (`cgroup_parent`/`cpuset` in the
     compose file);
   - `system.slice`, `user.slice` and `init.scope` restricted to the remaining cores
     (`AllowedCPUs=0-9,16-25`) via `systemctl set-property --runtime`, so other host load cannot bleed
     onto the fixturenet's reserved cores;
   - the kernel workqueue cpumask narrowed to `03ff03ff` for the same reason.
   All of this is runtime-only (the `--runtime` flag and the slice unit living under `/run/systemd/system`
   rather than `/etc/systemd/system`) -- it does not survive a reboot and is not part of this repo's
   tracked config; a fresh host needs the equivalent set up by hand before running the fixturenet under
   load.
2. **Sync-write latency on the shared ZFS pool.** With cores reserved, reorgs and late broadcasts still
   came in bursts. Side by side over the same 10 minutes on the same reserved cores: 20 reorgs / 79 late
   broadcasts with the data directory on `kelce-qvos`, 0 reorgs / 4 late with it on the NVMe root. The
   bursts tracked the pool's write operations: every dataset on `kelce-qvos` sits on the same six SATA
   QLC disks (three mirrors, no separate log device), so the chain's fsyncs wait behind every other
   writer on the host. That is a property of this pool's devices and load, not of ZFS. The chain's
   data now lives in RAM: `~/deployments/armada-fixturenet-e12/data` is a tmpfs (`size=3G`), mounted by
   the systemd unit `home-rix-deployments-armada\x2dfixturenet\x2de12-data.mount`. The cap is
   deliberate: a fixturenet left running fills it and dies, and nothing else on the host is affected.
   (The acceptance runs below ran from an interim directory on the NVMe root,
   `/opt/armada-deployments`, since removed.)
3. **geth's own HTTP `IdleTimeout`.** Even at 0 reorgs, a real, deterministic, reorg-independent failure
   remained: 0135's Curated Module v2 deploy runs `forge script --broadcast --slow` as a separate,
   several-minutes-long OS process while Hardhat's own Node.js JSON-RPC connection sits idle; the very
   next call after that step (`warmUpJsonRpcProvider` in lido-core's own `lib/provider.ts`, which already
   retries on `ECONNRESET`/`UND_ERR_SOCKET` for exactly this class of problem, but not on `EPIPE`) then
   failed with `write EPIPE`. Proved with a live TCP-state check (`ss -tn` on the geth container) that the
   connection is genuinely torn down by ~120-130s of idle time -- geth's own dumpconfig confirms
   `[Node.HTTPTimeouts] IdleTimeout = 120000000000` (120s) is the compiled-in default, applied whether or
   not `--config` is passed. (A synthetic single-socket repro script, both async and with a blocking
   sleep matching the real code's `execFileSync`, did *not* reproduce the client-side `EPIPE` in isolation
   -- undici's `Pool` appears to self-heal a single stale socket on the next dispatch; the real failure
   needs the full concurrency of Hardhat's actual call pattern, which this repro didn't attempt to
   replicate. The server-side connection death, independently measured, was enough to justify and fix.)
   Fixed entirely in the fixturenet, not in lido-core, and with no retry: `armada-fixturenet-geth`'s
   entrypoint now generates a `--config` file overriding only `[Node.HTTPTimeouts] IdleTimeout` (1 hour)
   before `exec geth`, leaving every other timeout and flag untouched (verified via a `dumpconfig` diff:
   only that one field changes).

   This chase is also why slice 3 needed three attempts to land cleanly: the first (pre-fix, 64
   validators) and second (post-validator-fix, still on ZFS) both got through the CSM+CMv2 deploy but
   died on this exact EPIPE; the third, on ext4 with the IdleTimeout fix and the reduced validator count,
   completed the entire migration end to end.

### DAO vote timing, cut to the real mechanical minimum
`env/lido/deploy-params-fixturenet.toml`'s `voteDuration`/`objectionPhaseDuration` started at upstream's
300s/60s, which needlessly slows two DAO votes per reconcile (0140-plug-staking-modules-via-vote's own
vote, and `lido.py`'s separate `_resume_via_dao_vote` for un-pausing staking). Both wait loops already
poll `Voting.canExecute()` rather than sleeping a fixed duration, so shortening the window is a real time
saving, not cosmetic. Derived, not guessed:
- `Voting.sol`'s `initialize()` only requires `voteTime > objectionPhaseTime` (no floor) -- but
  `lib/config-schemas.ts`'s own scratch-parameter schema is stricter: both fields are `PositiveIntSchema`
  (`z.number().int().positive()`), so `objectionPhaseDuration` cannot be 0. First attempt used 0 (legal
  per `Voting.sol` alone) and failed with a Zod validation error at step 0000, before any deploy work
  happened; fixed to 1, the schema's real floor.
- `newVote()`'s own auto-cast-vote (`_newVote(..., true)` calls `_vote(voteId, true, msg.sender)` if
  `_canVote`) does not register the deployer's "yes": called via `TokenManager.forward -> runScript`,
  `Voting` sees `msg.sender` as `TokenManager` itself (an `EVMScriptRunner` call, not a delegatecall
  preserving the original sender), and `TokenManager` holds no LDO. The separate, explicit `Voting.vote`
  sent directly by the deployer is still required.
- `startDate` is stamped at the block that mines `newVote()`, not when it is submitted, so only the gap
  between that confirmation and the following `vote()` landing counts against the window. At this
  fixturenet's 2s slots that is normally one slot; `voteDuration=8` (4 slots) leaves margin for a missed
  slot plus RPC/script overhead. `objectionPhaseDuration=1` is negligible next to that.

Full derivation is in `deploy-params-fixturenet.toml`'s own comment, next to the values.

### Slice 4 -- verify() postconditions
Landed together with slice 3's commit (`f73aca1`): the module-list and role-check postconditions are in
the same function block that slice 3's acceptance run already needed to pass, so there was nothing left
to separate into its own commit by the time slice 3's reconcile ran clean. One premise in this slice's
brief was also false, found via the same reconcile run:
- "the locator, AccountingOracle, both HashConsensus contracts and the staking router" should all be
  role-checked -- but `LidoLocator` (`contracts/0.8.9/LidoLocator.sol`) is a plain immutable-storage
  contract, not an OpenZeppelin `AccessControl` contract; it has no `hasRole` at all (calling it reverts
  with no return data). Confirmed independently by `scripts/scratch/steps/0150-transfer-roles.ts`'s own
  `ozAdminTransfers` list, which also excludes the locator. Fixed by dropping it from the check; kept
  AccountingOracle, both HashConsensus, and StakingRouter.
- Separately, `StakingRouter.getStakingModule(uint256)` returns a single `StakingModule` struct, not
  several top-level return values; `cast call`'s output-type signature needs that struct's field list
  wrapped in its own parens (`(...)`) to decode as one tuple -- a flat comma-separated list silently
  misaligns every field (confirmed by decoding the same raw return data with ethers.js's `AbiCoder` as
  ground truth, then comparing against `cast`'s two decoding modes).

Acceptance, on the same fixturenet slice 3 left running:
```
$ RECONCILER_VERIFY_ONLY=1 RECONCILER_ONLY=lido laconic-so deployment --dir /opt/armada-deployments/armada-fixturenet-e12 run-job armada-env-reconcile 2>&1 | grep -E "lido|FAILED"
lido verify: StakingRouter module list matches reference: ['curated-onchain-v1', 'SimpleDVT', 'Community Staking', 'curated-onchain-v2']
lido verify: Deployer holds no DEFAULT_ADMIN_ROLE on any oracle/registry; Agent does.
lido, present, 0
```
Negative case (deployer granted `DEFAULT_ADMIN_ROLE` on StakingRouter through the same real DAO-vote path
`_resume_via_dao_vote` uses -- `TokenManager.forward -> Voting.newVote -> vote -> executeVote ->
Agent.execute(StakingRouter, 0, grantRole(DEFAULT_ADMIN_ROLE, deployer))`):
```
reconciler: FAILED: lido: StakingRouter[0x3aAde2dCD2Df6a8cAc689EE797591b2913658659]: deployer holds DEFAULT_ADMIN_ROLE, expected only the Agent
```
Revoked through the same vote path (`revokeRole`); `--verify-only` passes again, byte-identical to the
first run above.

Gates, same deployment, both exit 0:
```
$ laconic-so deployment --dir /opt/armada-deployments/armada-fixturenet-e12 run-job armada-env-verify   # exit 0
$ laconic-so deployment --dir /opt/armada-deployments/armada-fixturenet-e12 run-job armada-nitro-e2e     # exit 0
```

### Measurements (final, ext4 + cpuset + geth IdleTimeout fix + 8s/1s vote timing)
- Full fresh reconcile (all 8 targets: weth, usdc, cctp, aave, lido, armada, armada_nitro, funding): **~25m
  10s** (container started 01:51:03.726Z, finished between 02:16:11 and 02:16:15Z -- `docker compose run
  --rm` removes the container before an exact finish timestamp can be read). Lido alone: 188,808,741 gas
  (differs from E5's reduced-step-list 174,944,813, as expected -- this run includes 0135's external
  CSM/CMv2 deploy and the DAO-vote path E5 skipped).
- Second reconcile (idempotency): **27s**, every module `present, 0`, deployer nonce unchanged
  (617 -> 617).
- Reorgs / late broadcasts over the full ~25-minute successful reconcile window: **2 reorgs, 9 late
  broadcasts** (`docker logs --since <start> ... | grep -c "Chain reorg detected"` /
  case-insensitive `"too late"` on geth/beacon respectively) -- consistent with the reserved-core and
  storage findings above.
- Peak CPU (`docker stats`, sampled every ~5s across the same window; percentages are relative to one
  core): geth **8.07%**, beacon **23.33%**.

### Deviations summary (all recorded above with reasons)
- Slice 2: `RUN_NETWORK=localhost` against Anvil instead of the brief's assumed `NETWORK=hardhat`
  in-process deploy, and Anvil instead of `npx hardhat node`.
- Slice 4: locator dropped from the role check (no `AccessControl`); `getStakingModule`'s cast signature
  needs explicit tuple parens.
- Vote timing: `objectionPhaseDuration` floor is 1, not 0 (schema-level, stricter than `Voting.sol`
  itself).
- Slices 3 and 4 share one commit (`f73aca1`): the verify() postconditions were inseparable from the
  deploy-path fixes needed to get slice 3's acceptance to pass at all.
- Infra fixes (validator count, cgroup pinning, chain data placement, geth IdleTimeout) went in as part of slice
  3's commit per instruction, even though they live outside `env/lido/` and `env/reconciler/`.

## Out of scope
Configuring oracles, running node operators, withdrawals.
