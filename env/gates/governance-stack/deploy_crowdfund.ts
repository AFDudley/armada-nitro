// ABOUTME: Deploys ArmadaCrowdfund using shared ARM token and treasury from governance deployment.
// ABOUTME: Reads USDC from CCTP deployment, sets the ARM transfer allowlist, and writes the crowdfund-hub manifest.

/**
 * Deploy Armada Crowdfund Contract
 *
 * Deploys ArmadaCrowdfund using the shared ARM token and treasury from
 * the governance deployment. Governance must be deployed first.
 *
 * Uses the shared USDC from the CCTP deployment (both local and testnet).
 *
 * Usage (local):
 *   npx hardhat run scripts/deploy_crowdfund.ts --network hub
 *
 * Usage (sepolia):
 *   npx hardhat run scripts/deploy_crowdfund.ts --network sepoliaHub
 */

import { ethers } from "hardhat";
import {
  getNetworkConfig,
  getChainRole,
  getCCTPDeploymentFile,
  getCrowdfundDeploymentFile,
  getPrivacyPoolDeploymentFile,
  getGovernanceDeploymentFile,
  isLocal,
} from "../config/networks";
import {
  createNonceManager,
  crowdfundHandoffNonce,
  rejectAnvilAddresses,
  loadDeployment,
  saveDeployment,
  saveDeploymentInProgress,
  assertDeploymentComplete,
  resolveCrowdfundOpenTimestamp,
} from "./deploy-utils";
import {
  MULTICALL3_ADDRESS,
  MULTICALL3_RUNTIME_BYTECODE,
} from "./multicall3-bytecode";

interface CrowdfundDeployment {
  chainId: number;
  deployer: string;
  deployBlock: number;
  contracts: {
    armToken: string;
    usdc: string;
    crowdfund: string;
    treasury: string;
  };
  config: {
    baseSale: string;
    maxSale: string;
    minSale: string;
    armPrice: string;
    armFunded: string;
  };
  timestamp: string;
}

// c1: the production window duration for the mainnet config — 21 days in seconds.
export const CROWDFUND_PRODUCTION_WINDOW_SECONDS = 21 * 24 * 60 * 60; // 1814400

// c2/c3/c4: a mainnet deploy with a non-21-day window duration is rejected before any
// transaction is sent; non-mainnet (local/fixturenet) may use a short window.
export interface WindowCheckResult {
  accepted: boolean;
  deploy_started: boolean;
  error_mentions_window_duration: boolean;
  error: string;
}

export function checkCrowdfundWindow(
  env: string,
  windowDuration: number,
): WindowCheckResult {
  const isMainnet = env === "mainnet";
  const accepted =
    !isMainnet || windowDuration === CROWDFUND_PRODUCTION_WINDOW_SECONDS;
  const error = accepted
    ? ""
    : `ArmadaCrowdfund window duration ${windowDuration}s is not the production value ${CROWDFUND_PRODUCTION_WINDOW_SECONDS}s (21 days)`;
  return {
    accepted,
    deploy_started: accepted,
    error_mentions_window_duration:
      !accepted && error.includes(String(windowDuration)),
    error,
  };
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);
  const config = getNetworkConfig();

  const role = getChainRole(chainId);
  if (!role) {
    console.error(`Unknown chain ID: ${chainId}`);
    process.exit(1);
  }

  console.log("=== Deploying Armada Crowdfund ===");
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Chain ID: ${chainId}`);
  console.log(`Environment: ${config.env}`);
  console.log("");

  // Fresh Anvil has no Multicall3; etch it locally (idempotent). A real local chain (a
  // fixturenet's geth, not Anvil) has no anvil_setCode RPC method at all -- Multicall3 is a
  // dev-UI convenience the crowdfund deploy/constructor never reads, so a geth fixturenet
  // skips the etch (warns) instead of failing the whole deploy over a missing debug RPC.
  if (isLocal()) {
    const existing = await ethers.provider.getCode(MULTICALL3_ADDRESS);
    if (existing === "0x") {
      try {
        await ethers.provider.send("anvil_setCode", [
          MULTICALL3_ADDRESS,
          MULTICALL3_RUNTIME_BYTECODE,
        ]);
        console.log(`Etched Multicall3 at ${MULTICALL3_ADDRESS}`);
        console.log("");
      } catch (err) {
        console.log(
          `Skipping Multicall3 etch (anvil_setCode unavailable on this chain, e.g. a real geth fixturenet): ${(err as Error).message}`,
        );
        console.log("");
      }
    }
  }

  // 1. Load governance deployment (shared ARM token, Safe treasury, RevenueLock).
  console.log("1. Loading governance deployment...");
  const govFilename = getGovernanceDeploymentFile();
  const govDeployment = loadDeployment(govFilename);
  if (!govDeployment) {
    throw new Error(
      `Governance deployment not found (${govFilename}). Deploy Baal and the Safe first.`,
    );
  }
  assertDeploymentComplete(govDeployment, govFilename);
  const nm = await createNonceManager(
    deployer,
    crowdfundHandoffNonce(govDeployment, config.hardenTimelock, isLocal()),
  );
  const armTokenAddress = govDeployment.contracts.armToken;
  const treasuryAddress = govDeployment.contracts.treasury;
  const revenueLockAddress = govDeployment.contracts.revenueLock;
  const reserveAddress: string | undefined =
    govDeployment.contracts.revenueReserveDistributor;
  if (Boolean(reserveAddress) !== Boolean(config.revenueReserve)) {
    throw new Error(
      "Reserve config and governance manifest disagree; refusing to continue",
    );
  }
  console.log(`   ARM Token (shared): ${armTokenAddress}`);
  console.log(`   Treasury (Safe): ${treasuryAddress}`);
  console.log(`   RevenueLock: ${revenueLockAddress}`);
  const armToken = await ethers.getContractAt("ArmadaToken", armTokenAddress);

  // 2. Load shared USDC from CCTP deployment.
  console.log("2. Loading USDC from CCTP deployment...");
  const cctpFilename = getCCTPDeploymentFile(role);
  const cctpDeployment = loadDeployment(cctpFilename);
  if (!cctpDeployment) {
    throw new Error(
      `CCTP deployment not found (${cctpFilename}). Run deploy_cctp first.`,
    );
  }
  const usdcAddress: string = cctpDeployment.contracts.usdc;
  console.log(`   USDC (shared): ${usdcAddress}`);

  // 2.5 Load the PrivacyPool address (ArmadaCrowdfund shields its proceeds to the Safe through
  //     the pool — G5-shield). The pool is deployed by deploy_privacy_pool.
  const poolFilename = getPrivacyPoolDeploymentFile(role);
  const poolDeployment = loadDeployment(poolFilename);
  if (!poolDeployment) {
    throw new Error(
      `PrivacyPool deployment not found (${poolFilename}). Run deploy_privacy_pool first.`,
    );
  }
  const poolAddress: string = poolDeployment.contracts.privacyPool;
  console.log(`   PrivacyPool: ${poolAddress}`);

  // 3. Deploy ArmadaCrowdfund (treasury is the immutable destination).
  console.log("3. Deploying ArmadaCrowdfund...");
  const ArmadaCrowdfund = await ethers.getContractFactory("ArmadaCrowdfund");
  const latestBlock = await ethers.provider.getBlock("latest");
  const openTimestamp = resolveCrowdfundOpenTimestamp(
    config.crowdfundOpenTime,
    config.crowdfundOpenDelay,
    latestBlock!.timestamp,
    0,
  );
  console.log(
    `   Open time: ${openTimestamp} (${new Date(openTimestamp * 1000).toISOString()})`,
  );
  // Security council: config-driven for non-local, Anvil signer[10] fallback for local.
  let securityCouncilAddress: string;
  if (config.securityCouncilAddress) {
    securityCouncilAddress = config.securityCouncilAddress;
  } else if (isLocal()) {
    const signers = await ethers.getSigners();
    securityCouncilAddress = signers[10].address;
  } else {
    throw new Error(
      "SECURITY_COUNCIL_ADDRESS is required for non-local deployments",
    );
  }
  rejectAnvilAddresses([securityCouncilAddress], "Security council");
  if (securityCouncilAddress.toLowerCase() === deployer.address.toLowerCase()) {
    throw new Error(
      "Security council address must differ from deployer address",
    );
  }
  // Launch team: config-driven for non-local, deployer fallback for local.
  let launchTeamAddress: string;
  if (config.launchTeamAddress) {
    launchTeamAddress = config.launchTeamAddress;
    rejectAnvilAddresses([launchTeamAddress], "Launch team");
    if (launchTeamAddress.toLowerCase() === deployer.address.toLowerCase()) {
      throw new Error("Launch team address must differ from deployer address");
    }
  } else if (isLocal()) {
    launchTeamAddress = deployer.address;
  } else {
    throw new Error(
      "LAUNCH_TEAM_ADDRESS is required for non-local deployments",
    );
  }
  console.log(`   Launch team: ${launchTeamAddress}`);
  console.log(`   Security council: ${securityCouncilAddress}`);
  // c2/c3: mainnet must deploy with exactly 21 days; refuse to start otherwise.
  const checkResult = checkCrowdfundWindow(
    config.env,
    config.crowdfundWindowDuration,
  );
  if (!checkResult.accepted) {
    throw new Error(checkResult.error);
  }

  const crowdfund = await ArmadaCrowdfund.deploy(
    usdcAddress,
    armTokenAddress,
    treasuryAddress,
    launchTeamAddress,
    securityCouncilAddress,
    openTimestamp,
    config.crowdfundWindowDuration,
    poolAddress,
    nm.override(),
  );
  const crowdfundReceipt = await crowdfund.deploymentTransaction()!.wait();
  const crowdfundDeployBlock = crowdfundReceipt!.blockNumber;
  const crowdfundAddress = await crowdfund.getAddress();
  console.log(
    `   ArmadaCrowdfund: ${crowdfundAddress} (block ${crowdfundDeployBlock})`,
  );

  const outputFile = getCrowdfundDeploymentFile();
  const deployment: CrowdfundDeployment = {
    chainId,
    deployer: deployer.address,
    deployBlock: crowdfundDeployBlock,
    contracts: {
      armToken: armTokenAddress,
      usdc: usdcAddress,
      crowdfund: crowdfundAddress,
      treasury: treasuryAddress,
    },
    config: {
      baseSale: "1200000",
      maxSale: "1800000",
      minSale: "1000000",
      armPrice: "1.00",
      armFunded: config.armDistribution.crowdfund,
    },
    timestamp: new Date().toISOString(),
  };
  saveDeploymentInProgress(outputFile, deployment);

  // 4. Set the ARM transfer allowlist (one-shot). Per ARM_TOKEN.md: crowdfund,
  //    treasury, RevenueLock, deployer, and the reserve distributor when present.
  console.log("4. Setting ARM transfer whitelist...");
  await (
    await armToken.initWhitelist(
      [
        crowdfundAddress,
        treasuryAddress,
        revenueLockAddress,
        deployer.address,
        ...(reserveAddress ? [reserveAddress] : []),
      ],
      nm.override(),
    )
  ).wait();
  console.log(
    `   initWhitelist: [crowdfund, treasury, revenueLock, deployer${reserveAddress ? ", reserve" : ""}]`,
  );

  // The Baal and Safe wiring of the crowdfund (quorum exclusion, delegation
  // authorization, ARM distribution and the exit path) is part of the open
  // Baal/Safe deployment-wiring work, not this stage.
  deployment.timestamp = new Date().toISOString();
  saveDeployment(outputFile, deployment);
  console.log(`\nDeployment saved to: deployments/${outputFile}`);
  console.log("\n=== Crowdfund deployment complete ===");
}

// Only run when executed directly (ts-node or `hardhat run`); a plain import (e.g. from the
// c5 mocha test) must not trigger the deploy.
const argv1 = process.argv[1] || "";
const isDirect =
  require.main === module || argv1.endsWith("deploy_crowdfund.ts");
if (isDirect) {
  main()
    .then(() => {
      process.exit(0);
    })
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}
