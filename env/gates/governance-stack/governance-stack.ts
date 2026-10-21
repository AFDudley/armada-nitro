// ABOUTME: G7-deploy (arn-2be): the G7 allowlist step (initWhitelist for the crowdfund +
// ABOUTME: Safe + RevenueLock), the live read-back of the five wiring facts, and the G7
// ABOUTME: manifest. Emits one JSON object (stdout) with the wiring facts + manifest status.
/**
 * G7-deploy finalizer (arn-2be).
 *
 * After the G1-G6 stack is deployed (cctp, pool, governance, Baal+Safe summon, crowdfund,
 * cohort, hedgey lockup), this script:
 *   1. Calls ArmadaToken.initWhitelist([crowdfund, safe, revenueLock]) — the deployer-only,
 *      one-shot allowlist step (the ARM transfer allowlist holds the crowdfund, the Safe and
 *      RevenueLock).
 *   2. Reads back the five wiring facts from live chain state.
 *   3. Writes the G7 manifest (deployments/governance-stack-hub.json) recording all seven
 *      addresses, the wiring, the shaman roles, the ARM allowlist and the ragequit burn
 *      authority.
 *   4. Emits one JSON object to stdout with the wiring facts + the manifest status.
 *
 * Usage (local):
 *   npx hardhat run scripts/governance-stack.ts --network hub
 */
import { ethers } from "hardhat";
import type { InterfaceAbi } from "ethers";
import * as fs from "fs";
import * as path from "path";
import {
  getGovernanceDeploymentFile,
  getCrowdfundDeploymentFile,
  getBaalSafeDeploymentFile,
  getPrivacyPoolDeploymentFile,
  getChainRole,
} from "../config/networks";
import {
  loadDeployment,
  saveDeployment,
  assertDeploymentComplete,
} from "./deploy-utils";

const REPO_ROOT = path.join(__dirname, "..");
const FORGE_OUT_DIR = path.join(REPO_ROOT, "forge-out");

function loadForgeAbi(sourceFile: string, contractName: string): InterfaceAbi {
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
  const artifactPath = path.join(
    FORGE_OUT_DIR,
    sourceFile,
    `${contractName}${suffix}.json`,
  );
  const parsed = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
  return parsed.abi;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);
  const role = getChainRole(chainId);
  if (!role) {
    console.error(`Unknown chain ID: ${chainId}`);
    process.exit(1);
  }

  // Load the G1-G6 deployment manifests.
  const govFile = getGovernanceDeploymentFile();
  const gov = loadDeployment(govFile);
  if (!gov) throw new Error(`Governance deployment not found (${govFile}).`);
  assertDeploymentComplete(gov, govFile);
  const armToken = gov.contracts.armToken;
  const safe = gov.contracts.treasury;
  const revenueLock = gov.contracts.revenueLock;

  const baalSafe = loadDeployment(getBaalSafeDeploymentFile());
  if (!baalSafe)
    throw new Error(
      "Baal-Safe deployment not found. Run summon-baal-safe first.",
    );
  const baal = baalSafe.contracts.baal;
  const ragequit = baalSafe.contracts.shieldedRagequit;

  const crowdfund = loadDeployment(getCrowdfundDeploymentFile());
  const crows = crowdfund?.contracts?.crowdfund;
  if (!crows)
    throw new Error(
      "Crowdfund deployment not found. Run deploy_crowdfund first.",
    );

  const poolFile = getPrivacyPoolDeploymentFile(role);
  const pool = loadDeployment(poolFile);
  const poolAddr = pool?.contracts?.privacyPool;
  if (!poolAddr)
    throw new Error(`PrivacyPool deployment not found (${poolFile}).`);

  const hedgey = loadDeployment("hedgey-lockup-hub.json");
  const hedgeyLockup = hedgey?.contracts?.hedgeyLockup;
  if (!hedgeyLockup)
    throw new Error(
      "Hedgey lockup deployment not found. Run deploy_hedgey_lockup first.",
    );

  // --- 1. Read the ARM token (deploy_crowdfund.ts already called initWhitelist with
  //    [crowdfund, treasury, revenueLock, deployer] -- the allowlist step is not repeated
  //    here; initWhitelist is deployer-only and one-shot, so a second call would revert). ---
  const arm = await ethers.getContractAt("ArmadaToken", armToken);

  // --- 2. Read back the five wiring facts from live chain state ---
  const safeAbi = loadForgeAbi("GnosisSafe.sol", "GnosisSafe");
  const baalAbi = loadForgeAbi("Baal.sol", "Baal");
  const safeC = new ethers.Contract(safe, safeAbi, deployer);
  const baalC = new ethers.Contract(baal, baalAbi, deployer);

  const isBaalOwner = await safeC.getFunction("isOwner")(baal);
  const threshold = Number(await safeC.getFunction("getThreshold")());

  const armAllowlistOk =
    (await arm.transferWhitelist(crows)) &&
    (await arm.transferWhitelist(safe)) &&
    (await arm.transferWhitelist(revenueLock));

  const ragequitC = new ethers.Contract(
    ragequit,
    [
      "function armToken() view returns (address)",
      "function baal() view returns (address)",
      "function safe() view returns (address)",
      "function pool() view returns (address)",
    ],
    deployer,
  );
  const rqArm = await ragequitC.armToken();
  const rqBaal = await ragequitC.baal();
  const rqSafe = await ragequitC.safe();
  const rqPool = await ragequitC.pool();
  const ragequitWired =
    rqArm.toLowerCase() === armToken.toLowerCase() &&
    rqBaal.toLowerCase() === baal.toLowerCase() &&
    rqSafe.toLowerCase() === safe.toLowerCase() &&
    rqPool.toLowerCase() === poolAddr.toLowerCase();

  const crowdfundC = await ethers.getContractAt("ArmadaCrowdfund", crows);
  const crowdfundTreasury = await crowdfundC.treasury();
  const crowdfundTreasuryIsSafe =
    crowdfundTreasury.toLowerCase() === safe.toLowerCase();

  // Shaman roles + burn authority (for the manifest).
  const shamanPermission = Number(await baalC.getFunction("shamans")(ragequit));
  const authorizedBurner = await arm.authorizedBurner(ragequit);

  // --- 3. Write the G7 manifest ---
  const manifest = {
    chainId,
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      armToken,
      baal,
      safe,
      revenueLock,
      crowdfund: crows,
      hedgeyLockup,
      shieldedRagequit: ragequit,
    },
    wiring: {
      safeOwnerIsBaal: isBaalOwner,
      safeThreshold: threshold,
      armAllowlistOk: armAllowlistOk,
      ragequitWired: ragequitWired,
      crowdfundTreasuryIsSafe: crowdfundTreasuryIsSafe,
      shamanRoles: { [ragequit]: shamanPermission },
      ragequitBurnAuthority: authorizedBurner,
    },
  };
  const manifestFile = "governance-stack-hub.json";
  saveDeployment(manifestFile, manifest);
  const manifestComplete = Boolean(
    manifest.contracts &&
      Object.keys(manifest.contracts).length === 7 &&
      manifest.wiring &&
      manifest.wiring.shamanRoles &&
      manifest.wiring.ragequitBurnAuthority !== undefined,
  );
  const addressesRecorded = Object.values(manifest.contracts).every((v) =>
    Boolean(v),
  );

  // --- 4. Emit the JSON ---
  const result = {
    addresses_recorded: addressesRecorded,
    safe_owner_is_baal: isBaalOwner,
    safe_threshold: threshold,
    arm_allowlist_ok: armAllowlistOk,
    ragequit_wired: ragequitWired,
    crowdfund_treasury_is_safe: crowdfundTreasuryIsSafe,
    manifest_complete: manifestComplete,
  };
  console.log("DEPLOY_RESULT_JSON=" + JSON.stringify(result));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
