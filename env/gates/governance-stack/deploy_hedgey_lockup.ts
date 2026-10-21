// ABOUTME: G7-deploy (arn-2be): deploys the vendored Hedgey TokenLockupPlans (the G5 team
// ABOUTME: lockup) on the fixturenet and writes its manifest with the lockup's live address.
/**
 * Deploy the Hedgey team lockup (G5).
 *
 * Deploys the vendored Hedgey TokenLockupPlans contract (lib/hedgey) and writes a manifest
 * recording its live address alongside the ARM token and the Safe (the timelock) from the
 * governance deployment.
 *
 * Reuses: the governance manifest (ARM token + the Safe as the timelock) and the forge-built
 * Hedgey artifact (forge-out/).
 *
 * Usage (local):
 *   npx hardhat run scripts/deploy_hedgey_lockup.ts --network hub
 */
import { ethers } from "hardhat";
import type { InterfaceAbi } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { execFileSync } from "child_process";
import { getGovernanceDeploymentFile } from "../config/networks";
import {
  loadDeployment,
  saveDeployment,
  saveDeploymentInProgress,
  assertDeploymentComplete,
} from "./deploy-utils";

const REPO_ROOT = path.join(__dirname, "..");
const FORGE_OUT_DIR = path.join(REPO_ROOT, "forge-out");

interface ForgeArtifact {
  abi: InterfaceAbi;
  bytecode: { object: string };
}

function loadForgeArtifact(
  sourceFile: string,
  contractName: string,
): ForgeArtifact {
  const versionSuffixes = [".0.8.20", ".0.8.17", ""];
  const suffix = versionSuffixes.find((s) =>
    fs.existsSync(
      path.join(FORGE_OUT_DIR, sourceFile, `${contractName}${s}.json`),
    ),
  );
  if (suffix === undefined) {
    throw new Error(
      `Forge artifact not found for ${contractName}. Run 'forge build' first.`,
    );
  }
  const parsed = JSON.parse(
    fs.readFileSync(
      path.join(FORGE_OUT_DIR, sourceFile, `${contractName}${suffix}.json`),
      "utf-8",
    ),
  );
  return { abi: parsed.abi, bytecode: parsed.bytecode };
}

interface HedgeyLockupDeployment {
  chainId: number;
  deployer: string;
  deployBlock: number;
  contracts: {
    hedgeyLockup: string;
    armToken: string;
    safe: string;
  };
  timestamp: string;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);
  console.log("=== Deploying Hedgey team lockup (G5) ===");
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Chain ID: ${chainId}`);
  console.log("");

  const govFilename = getGovernanceDeploymentFile();
  const govDeployment = loadDeployment(govFilename);
  if (!govDeployment) {
    throw new Error(
      `Governance deployment not found (${govFilename}). Run deploy_governance first.`,
    );
  }
  assertDeploymentComplete(govDeployment, govFilename);
  const armToken = govDeployment.contracts.armToken;
  const safe = govDeployment.contracts.treasury;

  console.log(
    "   Running 'forge build' to refresh the vendored Hedgey artifact...",
  );
  execFileSync("forge", ["build"], { cwd: REPO_ROOT, stdio: "inherit" });

  // 1. Deploy the Hedgey TokenLockupPlans (the G5 team lockup).
  console.log("1. Deploying Hedgey TokenLockupPlans...");
  const lockupArtifact = loadForgeArtifact(
    "TokenLockupPlans.sol",
    "TokenLockupPlans",
  );
  const LockupFactory = new ethers.ContractFactory(
    lockupArtifact.abi,
    lockupArtifact.bytecode.object,
    deployer,
  );
  const lockup = await LockupFactory.deploy("Hedgey TokenLockupPlans", "HDGY");
  const lockupReceipt = await lockup.deploymentTransaction()!.wait();
  const lockupAddress = await lockup.getAddress();
  const lockupDeployBlock = lockupReceipt!.blockNumber;
  console.log(
    `   Hedgey TokenLockupPlans: ${lockupAddress} (block ${lockupDeployBlock})`,
  );

  const outputFile = "hedgey-lockup-hub.json";
  saveDeploymentInProgress(outputFile, {
    chainId,
    deployer: deployer.address,
    contracts: { hedgeyLockup: lockupAddress, armToken, safe },
    deployBlock: lockupDeployBlock,
  });

  const deployment: HedgeyLockupDeployment = {
    chainId,
    deployer: deployer.address,
    deployBlock: lockupDeployBlock,
    contracts: {
      hedgeyLockup: lockupAddress,
      armToken,
      safe,
    },
    timestamp: new Date().toISOString(),
  };
  saveDeployment(outputFile, deployment);
  console.log(`\nHedgey lockup manifest saved: deployments/${outputFile}`);
  console.log("=== Hedgey team lockup deployment complete ===");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
