// ABOUTME: armada-assets-e2e gate (arn-ced), stage 1. The gate's own scenario script -- it reuses
// ABOUTME: env/gates/nitro-e2e/prepare.ts's wallet and proof code (c2) instead of re-implementing it.
/**
 * `armada-assets-e2e` gate, stage 1: E11 scenario 1 (Aave yield) and scenario 4 (redeem) --
 * docs/tasks/E11-aave-lido-channels.md.
 *
 * This gate reuses env/gates/nitro-e2e/prepare.ts's wallet and proof code (c2) by importing it:
 * prepare.ts's `main()` runs at its own top level, so the import below executes the same
 * real-proof wallet/shield/unshield stage `armada-nitro-e2e` uses, writing deposits.json. The
 * `armada-assets-e2e` job copies both files into the same relative layout this import expects
 * (stack/compose-jobs/armada-assets-e2e.yml) before running this script via hardhat.
 *
 * Stage 2 -- the Aave on-chain steps this gate is actually about (the hub custodian's ERC-4626
 * deposit into waUSDC, a second account's Aave supply + LTV-75% borrow, and the ERC-4626 redeem)
 * -- runs separately, in script/AssetsScenario.s.sol, driven by the job after this stage
 * completes. The job itself reads the yield evidence (waUSDC.convertToAssets(1e6), the Aave
 * pool's USDC liquidityIndex) with `cast`, before and after a real-block wait.
 *
 * Lido's oracle stays unconfigured in this job: no members, no reports, no price injection (c6).
 */

// c2: reuse the wallet and proof code from env/gates/nitro-e2e/prepare.ts -- importing it runs
// its stage 1 (shield + real-proof unshield) exactly as armada-nitro-e2e does.
import * as _prepare from "../nitro-e2e/prepare";

void _prepare;

console.log(
  "armada-assets-e2e stage 1 complete: reused env/gates/nitro-e2e/prepare.ts's wallet + proof " +
    "code. Stage 2 (Aave deposit/supply/borrow/redeem) runs in script/AssetsScenario.s.sol.",
);
