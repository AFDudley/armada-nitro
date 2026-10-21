// ABOUTME: Deploys one Baal (HausDAO feat/baalZodiac, vendored at lib/baal) backed by one
// ABOUTME: Gnosis Safe (vendored at lib/safe-contracts): the Safe's sole owner is the Baal,
// ABOUTME: threshold 1, no human owner at any point, and Baal's registered shares token is
// ABOUTME: G1's ArmadaToken (ARM); the loot token is a frozen BaalLootToken with zero supply.
// ABOUTME: G7a (arn-5c3): this copy additionally sets Baal's votingPeriod/gracePeriod from
// ABOUTME: BAAL_VOTING_PERIOD_SECONDS/BAAL_GRACE_PERIOD_SECONDS (harness config, unset = Baal's
// ABOUTME: own defaults). scripts/check_governance_stack.sh copies this file over the vendored
// ABOUTME: lib/armada-poc/scripts/summon-baal-safe.ts at run time and restores it on exit, the
// ABOUTME: same pattern it already uses for deploy_crowdfund.ts.

/**
 * Summon Baal + Safe (G2/arp-1f1; shares-token correction arp-932)
 *
 * Deploys / wires:
 * - ArmadaToken (G1's ARM) as Baal's registered SHARES token — loaded from the governance
 *   deployment, not deployed here (the crowdfund distributes this same ARM and ShieldedRagequit
 *   burns it, so Baal vote power is the holder's ARM balance).
 * - BaalLootToken ("Armada Loot"/LOOT) as Baal's loot token — its mint reverts forever, so the
 *   loot supply is zero at every moment (no loot holder can use Baal's native ragequit).
 * - Gnosis Safe (GnosisSafe template + GnosisSafeProxyFactory + MultiSend, vendored)
 * - Baal (template + zodiac ModuleProxyFactory clone, vendored)
 *
 * Wiring, in order (no human Safe owner at any point, even transiently):
 * 1. Deploy the Safe proxy with EMPTY setup data (zero owners, threshold 0 — not yet a
 *    functioning Safe, but critically: no owner of any kind exists yet, human or not).
 * 2. Clone the Baal template via zodiac's ModuleProxyFactory (a cheap view-function call,
 *    `avatar()`, satisfies deployModule's initializer requirement without touching storage).
 * 3. Call safe.setup(owners=[baalClone], threshold=1, ...), enabling the Baal as a Safe
 *    module in the same call (BaalSummoner.configureSafe's own pattern) — the Safe's FIRST
 *    and ONLY owner, from its very first owner-bearing state, is the Baal contract.
 * 4. Call baal.setUp(...), registering G1's ArmadaToken as Baal's shares token and the
 *    BaalLootToken as its loot token, with the Safe as Baal's avatar.
 * 5. Transfer ownership of the LOOT token to the Baal. ArmadaToken (shares) is a plain
 *    non-upgradeable ERC20 with no ownership to transfer; Baal only READS it (paused,
 *    name, symbol, getVotes, getPastVotes, totalSupply), and ARM's burn is gated to the
 *    ShieldedRagequit shaman (G3), so Baal can neither mint nor burn ARM.
 *
 * DESIGN (lab book decision 3: there is ONE ARM token, and it is the Baal shares token):
 *   ArmadaToken implements the surface Baal reads on its shares token — paused() (always
 *   false), the ERC-6372 timestamp vote clock (CLOCK_MODE() = "mode=timestamp", clock() =
 *   block.timestamp, so getPastVotes(voter, prop.votingStarts) reads the right weight), and
 *   getVotes/getPastVotes from delegated ARM. Its public mint reverts and its burn is callable
 *   only by the ShieldedRagequit shaman, so Baal cannot inflate or burn ARM. The loot token is
 *   a frozen BaalLootToken (mint reverts, supply zero forever).
 *
 * Usage (local):
 *   npx hardhat run scripts/summon-baal-safe.ts --network hub
 */

import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { execFileSync } from "child_process";
import {
  getGovernanceDeploymentFile,
  getBaalSafeDeploymentFile,
  getPrivacyPoolDeploymentFile,
  getChainRole,
} from "../config/networks";
import {
  createNonceManager,
  loadDeployment,
  saveDeployment,
  saveDeploymentInProgress,
  assertDeploymentComplete,
} from "./deploy-utils";

const REPO_ROOT = path.join(__dirname, "..");
const FORGE_OUT_DIR = path.join(REPO_ROOT, "forge-out");

interface ForgeArtifact {
  abi: ethers.InterfaceAbi;
  bytecode: { object: string };
}

/** Load a forge-compiled artifact (ABI + bytecode) for a vendored lib/ contract that Hardhat
 *  does not compile (lib/baal and lib/safe-contracts have no hardhat remappings — see
 *  foundry.toml for the forge-side remappings). `forge build` must have populated forge-out/
 *  first; this is run unconditionally below so the artifact is always current. */
function loadForgeArtifact(
  sourceFile: string,
  contractName: string,
): ForgeArtifact {
  // The forge build produces version-specific artifacts (e.g. `GnosisSafe.0.8.20.json`).
  const versionSuffixes = [".0.8.20", ".0.8.17", ""];
  for (const suffix of versionSuffixes) {
    const artifactPath = path.join(
      FORGE_OUT_DIR,
      sourceFile,
      `${contractName}${suffix}.json`,
    );
    if (fs.existsSync(artifactPath)) {
      const parsed = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
      return { abi: parsed.abi, bytecode: parsed.bytecode };
    }
  }
  const fallbackPath = path.join(
    FORGE_OUT_DIR,
    sourceFile,
    `${contractName}.json`,
  );
  throw new Error(
    `Forge artifact not found: ${fallbackPath}. Run 'forge build' first (this script does so automatically).`,
  );
}

interface BaalSafeDeployment {
  chainId: number;
  deployer: string;
  deployBlock: number;
  contracts: {
    safe: string;
    safeTemplate?: string;
    baal: string;
    baalTemplate: string;
    armToken: string;
    lootToken: string;
    multisend: string;
    g1ArmToken: string;
    shieldedRagequit?: string;
  };
  ownerHistory: Array<{
    step: string;
    owners: string[];
    humanOwners: string[];
  }>;
  timestamp: string;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);
  const nm = await createNonceManager(deployer);

  console.log("=== Summoning Baal + Safe (G2/arp-1f1) ===");
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Chain ID: ${chainId}`);
  console.log("");

  // 0. Load G1's ArmadaToken from the governance deployment. It IS Baal's shares token
  //    (lab book decision 3: one ARM token). The crowdfund distributes this same ARM and
  //    ShieldedRagequit burns it, so Baal vote power is the holder's ARM balance.
  const govFilename = getGovernanceDeploymentFile();
  const govDeployment = loadDeployment(govFilename);
  if (!govDeployment) {
    throw new Error(
      `Governance deployment not found (${govFilename}). Run deploy_governance first.`,
    );
  }
  assertDeploymentComplete(govDeployment, govFilename);
  const armTokenAddress: string = govDeployment.contracts.armToken;
  const safeAddress: string = govDeployment.contracts.treasury;
  console.log(`0. ARM shares token (G1 ArmadaToken): ${armTokenAddress}`);
  console.log(`   Safe (treasury, from governance): ${safeAddress}`);

  // Read the pool address from the privacy pool deployment manifest (needed for ShieldedRagequit).
  const role = getChainRole(chainId);
  if (!role) {
    console.error(`Unknown chain ID: ${chainId}`);
    process.exit(1);
  }
  const poolFilename = getPrivacyPoolDeploymentFile(role);
  const poolDeployment = loadDeployment(poolFilename);
  const poolAddress: string = poolDeployment?.contracts.privacyPool;
  if (poolAddress) {
    console.log(`   PrivacyPool: ${poolAddress}`);
  }

  // Ensure the vendored Baal/Safe forge artifacts are current (forge-out/ is not committed).
  console.log(
    "   Running 'forge build' to refresh vendored contract artifacts...",
  );
  execFileSync("forge", ["build"], { cwd: REPO_ROOT, stdio: "inherit" });

  const outputFile = getBaalSafeDeploymentFile();
  const progress: {
    contracts: Record<string, string>;
    [field: string]: unknown;
  } = {
    chainId,
    deployer: deployer.address,
    contracts: {},
  };
  const recordProgress = (
    contracts: Record<string, string>,
    extra: object = {},
  ) => {
    Object.assign(progress.contracts, contracts);
    Object.assign(progress, extra);
    saveDeploymentInProgress(outputFile, progress);
  };
  recordProgress({});

  const ownerHistory: BaalSafeDeployment["ownerHistory"] = [];
  async function recordOwnerHistory(step: string, safeAddress: string) {
    const safeForRead = new ethers.Contract(
      safeAddress,
      loadForgeArtifact("GnosisSafe.sol", "GnosisSafe").abi,
      deployer,
    );
    let owners: string[] = [];
    try {
      owners = await safeForRead.getOwners();
    } catch {
      owners = [];
    }
    const humanOwners: string[] = [];
    for (const owner of owners) {
      const code = await ethers.provider.getCode(owner);
      if (code === "0x") {
        humanOwners.push(owner);
      }
    }
    ownerHistory.push({ step, owners, humanOwners });
    console.log(
      `   [owner-history] step=${step} owners=${JSON.stringify(owners)} humanOwners=${JSON.stringify(humanOwners)}`,
    );
  }

  // 1. Deploy the frozen BaalLootToken as Baal's loot token. Its mint reverts forever, so the
  //    loot supply is zero at every moment; no loot holder can use Baal's native ragequit.
  console.log("1. Deploying BaalLootToken (frozen loot, zero supply)...");
  recordProgress({ armToken: armTokenAddress });
  const BaalLootToken = await ethers.getContractFactory("BaalLootToken");
  const lootToken = await BaalLootToken.deploy(nm.override());
  await lootToken.deploymentTransaction()!.wait();
  const lootTokenAddress = await lootToken.getAddress();
  recordProgress({ lootToken: lootTokenAddress });
  console.log(`   LOOT (BaalLootToken): ${lootTokenAddress}`);

  // 2. The Safe is already deployed by deploy_governance.ts (the treasury + ArmadaToken's
  //    immutable timelock). Summon reuses it — no second Safe is deployed here.
  console.log("2. Reusing the Safe from the governance manifest...");
  recordProgress({ safe: safeAddress });
  await recordOwnerHistory("safe-reused-from-governance", safeAddress);

  // 4. Deploy the vendored Baal template + zodiac ModuleProxyFactory, then clone the
  //    template — Baal's constructor disables initializers on the template itself, so
  //    setUp() must run against a clone's fresh storage (mirrors BaalSummoner._summonBaal).
  console.log(
    "4. Deploying Baal (template, zodiac ModuleProxyFactory, clone)...",
  );
  const baalArtifact = loadForgeArtifact("Baal.sol", "Baal");
  const moduleProxyFactoryArtifact = loadForgeArtifact(
    "ModuleProxyFactory.sol",
    "ModuleProxyFactory",
  );

  const BaalTemplateFactory = new ethers.ContractFactory(
    baalArtifact.abi,
    baalArtifact.bytecode.object,
    deployer,
  );
  const baalTemplate = await BaalTemplateFactory.deploy(nm.override());
  await baalTemplate.deploymentTransaction()!.wait();
  const baalTemplateAddress = await baalTemplate.getAddress();
  recordProgress({ baalTemplate: baalTemplateAddress });

  const ModuleProxyFactoryFactory = new ethers.ContractFactory(
    moduleProxyFactoryArtifact.abi,
    moduleProxyFactoryArtifact.bytecode.object,
    deployer,
  );
  const moduleProxyFactory = await ModuleProxyFactoryFactory.deploy(
    nm.override(),
  );
  await moduleProxyFactory.deploymentTransaction()!.wait();

  const avatarGetterSelector = ethers.id("avatar()").slice(0, 10);
  const deployModuleTx = await moduleProxyFactory.getFunction("deployModule")(
    baalTemplateAddress,
    avatarGetterSelector,
    0,
    nm.override(),
  );
  const deployModuleReceipt = await deployModuleTx.wait();
  const moduleProxyCreationEvent = deployModuleReceipt!.logs
    .map((log: ethers.Log) => {
      try {
        return moduleProxyFactory.interface.parseLog(log);
      } catch {
        return null;
      }
    })
    .find(
      (parsed: ethers.LogDescription | null) =>
        parsed?.name === "ModuleProxyCreation",
    );
  const baalAddress: string = moduleProxyCreationEvent!.args.proxy;
  recordProgress({ baal: baalAddress });
  console.log(`   Baal clone: ${baalAddress}`);

  // 4.5 Deploy the MultiSend library (needed for the Safe's setup + Baal's initialization
  //      multisend data). A fresh library is deployed here; the governance deploy's multisend is
  //      a separate contract (the multisend is a stateless library, so two instances are fine).
  const safeArtifact = loadForgeArtifact("GnosisSafe.sol", "GnosisSafe");
  const multisendArtifact = loadForgeArtifact("MultiSend.sol", "MultiSend");
  const MultiSendFactory = new ethers.ContractFactory(
    multisendArtifact.abi,
    multisendArtifact.bytecode.object,
    deployer,
  );
  const multisend = await MultiSendFactory.deploy(nm.override());
  await multisend.deploymentTransaction()!.wait();
  const multisendAddress = await multisend.getAddress();
  console.log(`   MultiSend library: ${multisendAddress}`);
  recordProgress({ multisend: multisendAddress });

  // 5. Call safe.setup(owners=[baal], threshold=1, ...), enabling Baal as a Safe module in
  //    the same call (BaalSummoner.configureSafe's own pattern). This is the Safe's FIRST
  //    owner-bearing state, and its only owner is the Baal contract — never a human key.
  const safe = new ethers.Contract(safeAddress, safeArtifact.abi, deployer);
  const enableBaalModuleCall = new ethers.Interface([
    "function enableModule(address module)",
  ]).encodeFunctionData("enableModule", [baalAddress]);
  const enableBaalMultisendEntry = ethers.solidityPacked(
    ["uint8", "address", "uint256", "uint256", "bytes"],
    [
      0,
      safeAddress,
      0,
      ethers.getBytes(enableBaalModuleCall).length,
      enableBaalModuleCall,
    ],
  );
  const multisendAction = new ethers.Interface([
    "function multiSend(bytes transactions)",
  ]).encodeFunctionData("multiSend", [enableBaalMultisendEntry]);
  const setupTx = await safe.getFunction("setup")(
    [baalAddress],
    1,
    multisendAddress,
    multisendAction,
    ethers.ZeroAddress,
    ethers.ZeroAddress,
    0,
    ethers.ZeroAddress,
    nm.override(),
  );
  await setupTx.wait();
  await recordOwnerHistory("safe-setup-complete", safeAddress);

  // 5.5 Deploy ShieldedRagequit BEFORE Baal.setUp, so its address is registered as the manager
  //     shaman inside the setUp init multisend. Baal.setShamans is baalOnly (msg.sender must be
  //     the avatar — the Safe). The only path where the Safe is the caller is the setUp init
  //     multisend, which Baal runs through the Safe module (execTransactionFromModule), so the
  //     sub-call to setShamans sees msg.sender == the Safe. A post-setUp setShamans from the
  //     deployer reverts "!baal". Constructor: (armToken, baal, safe, pool). The Baal clone
  //     address is already known (deployModule above).
  console.log("5.5 Deploying ShieldedRagequit (one Baal manager shaman)...");
  if (!poolAddress) {
    throw new Error(
      "PrivacyPool deployment not found; deploy the hub pool before summoning Baal + Safe.",
    );
  }
  // ShieldedRagequit links the PoseidonT4 library (it hashes the contract-owned payout note).
  // Deploy a fresh PoseidonT4 (a stateless hash library) and link it, as deploy_privacy_pool does.
  const poseidonBytecode: { PoseidonT4: { bytecode: string } } = JSON.parse(
    fs.readFileSync(
      path.join(REPO_ROOT, "lib", "poseidon_bytecode.json"),
      "utf-8",
    ),
  );
  const poseidonT4Tx = await deployer.sendTransaction({
    data: poseidonBytecode.PoseidonT4.bytecode,
    ...nm.override(),
  });
  const poseidonT4Receipt = await poseidonT4Tx.wait();
  const poseidonT4Address = poseidonT4Receipt!.contractAddress!;
  console.log(`   PoseidonT4 (for ShieldedRagequit): ${poseidonT4Address}`);
  const ShieldedRagequit = await ethers.getContractFactory("ShieldedRagequit", {
    libraries: { PoseidonT4: poseidonT4Address },
  });
  const ragequit = await ShieldedRagequit.deploy(
    armTokenAddress,
    baalAddress,
    safeAddress,
    poolAddress,
    nm.override(),
  );
  await ragequit.deploymentTransaction()!.wait();
  const ragequitAddress = await ragequit.getAddress();
  recordProgress({ shieldedRagequit: ragequitAddress });
  console.log(`   ShieldedRagequit: ${ragequitAddress}`);

  // 6. Register ARM/LOOT as Baal's shares/loot token, now that the Safe (avatar) exists, and
  //    register ShieldedRagequit as the one manager shaman (permission 2). Baal.setUp decodes
  //    (loot, shares, multisend, avatar, forwarder, initMultisendData) and runs the init
  //    multisend through the Safe module, so setShamans inside it passes baalOnly
  //    (msg.sender == the Safe). The init multisend MUST be a real multiSend(bytes) call, not
  //    raw empty bytes (raw empty bytes hits MultiSend's nonexistent fallback and reverts).
  const baal = new ethers.Contract(baalAddress, baalArtifact.abi, deployer);
  const setShamansCall = new ethers.Interface([
    "function setShamans(address[] _shamans, uint256[] _permissions)",
  ]).encodeFunctionData("setShamans", [[ragequitAddress], [2]]);
  const setShamansMultisendEntry = ethers.solidityPacked(
    ["uint8", "address", "uint256", "uint256", "bytes"],
    [0, baalAddress, 0, ethers.getBytes(setShamansCall).length, setShamansCall],
  );
  // BAAL_VOTING_PERIOD_SECONDS / BAAL_GRACE_PERIOD_SECONDS: Baal's `votingPeriod` and
  // `gracePeriod` (harness config, not a contract change). setGovernanceConfig is
  // baalOrGovernorOnly; it runs here through the same init multisend as setShamans, so
  // msg.sender is the Safe (the avatar) -- the one caller setGovernanceConfig accepts before
  // any shaman exists. Left unset (0), Baal's own defaults (both 0) are untouched --
  // setGovernanceConfig only reassigns a period when the decoded value is nonzero. The
  // fixturenet-only governance-lifecycle gate (env/gates/nitro-e2e/governance-lifecycle.sh)
  // sets both short so the one proposal's Baal.votingPeriod and Baal.gracePeriod complete
  // inside the gate's wall-clock budget.
  const votingPeriodSeconds = Number(
    process.env.BAAL_VOTING_PERIOD_SECONDS ?? 0,
  );
  const gracePeriodSeconds = Number(process.env.BAAL_GRACE_PERIOD_SECONDS ?? 0);
  const setGovernanceConfigCall = new ethers.Interface([
    "function setGovernanceConfig(bytes _governanceConfig)",
  ]).encodeFunctionData("setGovernanceConfig", [
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint32", "uint32", "uint256", "uint256", "uint256", "uint256"],
      [votingPeriodSeconds, gracePeriodSeconds, 0, 0, 0, 0],
    ),
  ]);
  const setGovernanceConfigMultisendEntry = ethers.solidityPacked(
    ["uint8", "address", "uint256", "uint256", "bytes"],
    [
      0,
      baalAddress,
      0,
      ethers.getBytes(setGovernanceConfigCall).length,
      setGovernanceConfigCall,
    ],
  );
  const initMultisend = new ethers.Interface([
    "function multiSend(bytes transactions)",
  ]).encodeFunctionData("multiSend", [
    ethers.concat([
      setShamansMultisendEntry,
      setGovernanceConfigMultisendEntry,
    ]),
  ]);
  const baalInitParams = ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "address", "address", "address", "address", "bytes"],
    [
      lootTokenAddress,
      armTokenAddress,
      multisendAddress,
      safeAddress,
      ethers.ZeroAddress,
      initMultisend,
    ],
  );
  console.log(
    `   Baal.setUp initParams (length ${baalInitParams.length} bytes)`,
  );
  const baalSetupTx = await baal.getFunction("setUp")(
    baalInitParams,
    nm.override(),
  );
  await baalSetupTx.wait();
  console.log(`   Baal.sharesToken() registered: ${armTokenAddress}`);
  console.log(
    `   Baal.shamans(${ragequitAddress}) = manager role (permission 2, via setUp init multisend)`,
  );

  // 7. Transfer ownership of the LOOT token to the Baal — only Baal can pause it (its mint
  //    and burn always revert). ArmadaToken (shares) is a plain non-upgradeable ERC20 with no
  //    ownership to transfer; Baal only reads it and ARM's burn is the ShieldedRagequit shaman.
  console.log("7. Transferring LOOT ownership to the Baal...");
  await (await lootToken.transferOwnership(baalAddress, nm.override())).wait();
  console.log(`   LOOT owner: ${baalAddress}`);

  // 8. Register ShieldedRagequit as the ARM burn authority. ArmadaToken.initBurners is
  //    deployer-only and one-shot; the same deployer EOA ran deploy_governance.
  console.log("8. Registering ShieldedRagequit as the ARM burner...");
  const armTokenContract = await ethers.getContractAt(
    "ArmadaToken",
    armTokenAddress,
  );
  await (
    await armTokenContract.initBurners([ragequitAddress], nm.override())
  ).wait();
  console.log(`   ArmadaToken.authorizedBurner(${ragequitAddress}) = true`);

  // ============ Read back and print the three facts ============
  const finalOwners: string[] = await safe.getFunction("getOwners")();
  const finalThreshold: bigint = await safe.getFunction("getThreshold")();
  const isBaalOwner: boolean = await safe.getFunction("isOwner")(baalAddress);
  const registeredSharesToken: string = await baal.getFunction("sharesToken")();
  const humanOwnersFinal: string[] = [];
  for (const owner of finalOwners) {
    const code = await ethers.provider.getCode(owner);
    if (code === "0x") {
      humanOwnersFinal.push(owner);
    }
  }

  console.log("");
  console.log("=== Baal + Safe summon complete ===");
  console.log(`Safe address: ${safeAddress}`);
  console.log(`Safe owners: ${JSON.stringify(finalOwners)}`);
  console.log(`Safe threshold: ${finalThreshold}`);
  console.log(`Safe human owner count: ${humanOwnersFinal.length}`);
  console.log(`Baal address: ${baalAddress}`);
  console.log(`Baal registered shares token: ${registeredSharesToken}`);
  console.log(`ARM shares token (G1 ArmadaToken): ${armTokenAddress}`);
  console.log(`Loot token (frozen BaalLootToken): ${lootTokenAddress}`);

  const resultJson = {
    safeAddress,
    safeOwners: finalOwners,
    safeThreshold: Number(finalThreshold),
    safeOwnerCount: finalOwners.length,
    safeHumanOwnerCount: humanOwnersFinal.length,
    baalIsSafeOwner: isBaalOwner,
    baalAddress,
    baalSharesToken: registeredSharesToken,
    armToken: armTokenAddress,
    sharesTokenIsArm:
      registeredSharesToken.toLowerCase() === armTokenAddress.toLowerCase(),
    g1ArmToken: armTokenAddress,
    ownerHistory,
  };
  console.log(`DEPLOY_RESULT_JSON=${JSON.stringify(resultJson)}`);

  const deployment: BaalSafeDeployment = {
    chainId,
    deployer: deployer.address,
    deployBlock: deployModuleReceipt!.blockNumber,
    contracts: {
      safe: safeAddress,
      baal: baalAddress,
      baalTemplate: baalTemplateAddress,
      armToken: armTokenAddress,
      lootToken: lootTokenAddress,
      multisend: multisendAddress,
      g1ArmToken: armTokenAddress,
      shieldedRagequit: ragequitAddress,
    },
    ownerHistory,
    timestamp: new Date().toISOString(),
  };
  saveDeployment(outputFile, deployment);
  console.log(`\nDeployment saved to: deployments/${outputFile}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
