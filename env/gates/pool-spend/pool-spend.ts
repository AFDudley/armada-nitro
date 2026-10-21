// ABOUTME: G7b-spend (arn-d62) gate: on the fixturenet governance stack, shield a note
// ABOUTME: directly into the real pool, spend it with a real Groth16 proof (SDK's
// ABOUTME: planSpend + prove), submit PrivacyPool.transact, and verify on chain that the
// ABOUTME: proof was accepted (nullifier recorded, new commitment inserted). Emits ONE JSON
// ABOUTME: object to a result file so the acceptance oracle reads pure JSON.
// ABOUTME: Reuses the nitro-e2e / pool-e2e gate pattern (same lib/sdk calls as
// ABOUTME: env/gates/pool-e2e/pool-e2e.ts), so no new harness. See
// ABOUTME: contracts/specs/derived-arn-d62.spec.json.

import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

import {
  initializeEngine,
  shutdownEngine,
  clearDatabase,
  getEngine,
} from "../lib/sdk/init";
import {
  createShieldRequest,
  generateShieldPrivateKey,
} from "../lib/sdk/shield";
import { createWallet, DEFAULT_ENCRYPTION_KEY } from "../lib/sdk/wallet";
import { initializeProver } from "../lib/sdk/prover";
import {
  createPrivateTransfer,
  submitTransaction,
  getSpendableBalance,
} from "../lib/sdk/transfer";
import {
  loadNetworkIntoEngine,
  scanWalletBalances,
} from "../lib/sdk/network";
import { getChainById, getRpcUrl } from "../lib/sdk/chain-config";
import { ChainType, Chain } from "@railgun-community/shared-models";
import {
  POI,
  POINodeInterface,
  RailgunWallet,
} from "@railgun-community/engine";

// POI (private proof-of-innocence attestation) is not part of this environment -- same stub
// as env/gates/pool-e2e/pool-e2e.ts and env/gates/nitro-e2e/prepare.ts use.
class StubPOINodeInterface extends POINodeInterface {
  isActive(): boolean {
    return false;
  }
  async isRequired(): Promise<boolean> {
    return false;
  }
  async getPOIsPerList() {
    return {};
  }
  async getPOIMerkleProofs() {
    return [];
  }
  async validatePOIMerkleroots(): Promise<boolean> {
    return true;
  }
  async submitPOI(): Promise<void> {
    /* no-op */
  }
  async submitLegacyTransactProofs(): Promise<void> {
    /* no-op */
  }
}
POI.init([], new StubPOINodeInterface());

// Event signatures = IShieldModule.Shield / ITransactModule.{Transact,Nullified,Unshield}
// (armada-poc contracts/privacy-pool/interfaces/), verified against the same ABI
// env/gates/pool-e2e/pool-e2e.ts decodes -- emitted via delegatecall from PrivacyPool, so
// PrivacyPool's own default ABI (ethers.getContractAt('PrivacyPool', ...)) does not include them.
const POOL_EVENT_ABI = [
  "event Shield(uint256 treeNumber, uint256 startPosition, tuple(bytes32 npk, tuple(uint8 tokenType, address tokenAddress, uint256 tokenSubID) token, uint120 value)[] commitments, tuple(bytes32[3] encryptedBundle, bytes32 shieldKey)[] shieldCiphertext, uint256[] fees)",
  "event Transact(uint256 treeNumber, uint256 startPosition, bytes32[] hash, tuple(bytes32[4] ciphertext, bytes32 blindedSenderViewingKey, bytes32 blindedReceiverViewingKey, bytes annotationData, bytes memo)[] ciphertext)",
  "event Nullified(uint16 treeNumber, bytes32[] nullifier)",
  "event Unshield(address to, tuple(uint8 tokenType, address tokenAddress, uint256 tokenSubID) token, uint256 amount, uint256 fee)",
];

const SHIELD_AMOUNT = ethers.parseUnits("10", 6); // 10 USDC shielded into the real pool
const SPEND_AMOUNT = ethers.parseUnits("3", 6); // 3 USDC private transfer (the spend)

/** Decode every log in a receipt matching one of `eventNames` (independent of lib/sdk). */
function decodeEvents(
  receipt: ethers.TransactionReceipt,
  eventNames: string[],
): Array<ethers.LogDescription> {
  const iface = new ethers.Interface(POOL_EVENT_ABI);
  const out: Array<ethers.LogDescription> = [];
  for (const log of receipt.logs) {
    const desc = iface.parseLog({ topics: log.topics, data: log.data });
    if (desc && eventNames.includes(desc.name)) out.push(desc);
  }
  return out;
}

async function waitForBalance(
  walletId: string,
  chain: Chain,
  wallet: RailgunWallet,
  tokenAddress: string,
  minAmount: bigint,
  timeoutMs: number,
): Promise<bigint> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    await scanWalletBalances(walletId, chain);
    const bal = await getSpendableBalance(wallet, chain, tokenAddress);
    if (bal >= minAmount) return bal;
    await new Promise((r) => setTimeout(r, 3000));
  }
  throw new Error(
    `spendable balance didn't reach ${minAmount} within ${timeoutMs / 1000}s`,
  );
}

async function main() {
  // --- 0. Read the pool manifest (the harness wrote it) ------------------------
  const REPO_ROOT = process.cwd(); // hardhat runs from the PoC dir
  const manifestPath = path.join(
    REPO_ROOT,
    "deployments",
    "privacy-pool-hub.json",
  );
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf-8"));
  const poolAddress: string = manifest.contracts.privacyPool;
  const usdcAddress: string = manifest.cctp.usdc;
  const deployBlock: number = manifest.deployBlock ?? 0;
  console.log(
    `pool=${poolAddress} usdc=${usdcAddress} deployBlock=${deployBlock}`,
  );

  const privacyPool = await ethers.getContractAt("PrivacyPool", poolAddress);
  const usdc = await ethers.getContractAt("MockUSDCV2", usdcAddress);

  // The payer is anvil account 1; the deployer (manifest.deployer, anvil account 0) is
  // MockUSDCV2's initial minter (contracts/cctp/MockUSDCV2.sol's constructor sets
  // minters[msg.sender] = true for whoever deploy_cctp_v3.ts ran as). Mint the payer's
  // shortfall directly -- self-contained, independent of the reconciler's funding module
  // (which tops up a *different* USDC: its own real FiatToken deploy, not this governance
  // stack's mock CCTP USDC at manifest.cctp.usdc).
  const signers = await ethers.getSigners();
  const payer = signers[1];
  const deployerSigner = signers.find(
    (s) => s.address.toLowerCase() === (manifest.deployer as string).toLowerCase(),
  );
  if (!deployerSigner) {
    throw new Error(
      `deployer ${manifest.deployer} not found among hub network signers`,
    );
  }
  const payerUsdcBalance: bigint = await usdc.balanceOf(payer.address);
  if (payerUsdcBalance < SHIELD_AMOUNT) {
    const shortfall = SHIELD_AMOUNT - payerUsdcBalance;
    await (await usdc.connect(deployerSigner).mint(payer.address, shortfall)).wait();
    console.log(
      `minted ${ethers.formatUnits(shortfall, 6)} USDC to payer ${payer.address}`,
    );
  }
  const payerUsdcBalanceAfter: bigint = await usdc.balanceOf(payer.address);
  console.log(
    `payer=${payer.address} USDC balance=${ethers.formatUnits(payerUsdcBalanceAfter, 6)}`,
  );

  // --- 1. Initialize the engine + prover (the same setup as the nitro-e2e gate) ---
  clearDatabase();
  await initializeEngine("poolspend");
  const chain: Chain = getChainById(31337) ?? {
    type: ChainType.EVM,
    id: 31337,
  };
  const rpcUrl = getRpcUrl(chain);
  await loadNetworkIntoEngine(
    chain,
    poolAddress,
    ethers.ZeroAddress,
    rpcUrl,
    deployBlock,
  );
  await initializeProver();

  // Create the two wallets: A (spends), B (recipient).
  const walletAInfo = await createWallet(DEFAULT_ENCRYPTION_KEY);
  const walletBInfo = await createWallet(DEFAULT_ENCRYPTION_KEY);
  const engine = getEngine();
  const railgunA = engine.wallets[walletAInfo.id] as unknown as RailgunWallet;
  const railgunB = engine.wallets[walletBInfo.id] as unknown as RailgunWallet;
  console.log(`wallet A (sender) = ${walletAInfo.railgunAddress}`);
  console.log(`wallet B (recipient) = ${walletBInfo.railgunAddress}`);

  // --- 2. Shield a note directly into the real pool (funded by the payer) --------
  const shieldPrivateKey = generateShieldPrivateKey();
  const { shieldRequest } = await createShieldRequest(
    {
      railgunAddress: walletAInfo.railgunAddress,
      amount: SHIELD_AMOUNT,
      tokenAddress: usdcAddress,
    },
    shieldPrivateKey,
  );
  await (await usdc.connect(payer).approve(poolAddress, SHIELD_AMOUNT)).wait();
  const shieldTx = await privacyPool
    .connect(payer)
    .shield([shieldRequest], ethers.ZeroAddress);
  const shieldReceipt = await shieldTx.wait();
  const shieldEvents = decodeEvents(shieldReceipt, ["Shield"]);
  if (shieldEvents.length !== 1)
    throw new Error(`expected 1 Shield event, saw ${shieldEvents.length}`);
  console.log(`shield tx ${shieldReceipt.hash}`);

  // Wait until the shielded note is spendable (the engine must scan it first).
  const spendable = await waitForBalance(
    walletAInfo.id,
    chain,
    railgunA,
    usdcAddress,
    SPEND_AMOUNT,
    60_000,
  );
  console.log(
    `wallet A spendable=${ethers.formatUnits(spendable, 6)} USDC (shielded note available)`,
  );

  // --- 3. Spend the note: planSpend (note selection) + prove (real Groth16 proof) ---
  // createPrivateTransfer wraps the SDK's planSpend (which UTXOs to spend) and prove
  // (the real Groth16 proof) -- the exact path the spec names.
  const transferResult = await createPrivateTransfer({
    wallet: railgunA,
    chain,
    tokenAddress: usdcAddress,
    recipientAddress: walletBInfo.railgunAddress,
    amount: SPEND_AMOUNT,
    encryptionKey: DEFAULT_ENCRYPTION_KEY,
    progressCallback: () => process.stdout.write("."),
  });
  console.log("\n");
  if (!transferResult.transactions.length) {
    throw new Error("planSpend/prove returned no proved transactions");
  }
  const provedTx = transferResult.transactions[0];
  console.log(
    `circuit shape: ${provedTx.nullifiers.length}x${provedTx.commitments.length}`,
  );

  // --- 4. Submit PrivacyPool.transact with the real proof -------------------------
  const transactReceipt = await submitTransaction(payer, transferResult);
  const transactEvents = decodeEvents(transactReceipt, ["Transact"]);
  const nullifiedEvents = decodeEvents(transactReceipt, ["Nullified"]);
  console.log(`transact tx ${transactReceipt.hash}`);
  if (transactEvents.length !== 1) {
    throw new Error(`expected 1 Transact event, saw ${transactEvents.length}`);
  }

  // proof_verified: the transact succeeded (a real Groth16 proof was accepted on chain).
  const proofVerified =
    transactEvents.length === 1 && nullifiedEvents.length >= 1;
  // nullifier_recorded: the pool recorded a new nullifier (a Nullified event fired).
  const nullifierRecorded =
    nullifiedEvents.length >= 1 &&
    nullifiedEvents[0].args.nullifier.length >= 1;
  // commitment_inserted: the pool inserted a new commitment (a Transact event with new
  // commitments = the change note). A transfer with a change note always inserts one.
  const commitmentInserted = transactEvents[0].args.hash.length >= 1;

  // Sanity: the recipient must now hold the spent amount (read back from the pool).
  await waitForBalance(
    walletBInfo.id,
    chain,
    railgunB,
    usdcAddress,
    SPEND_AMOUNT,
    60_000,
  );

  // --- 5. Emit the result JSON ---------------------------------------------------
  const result = {
    proof_verified: proofVerified,
    nullifier_recorded: nullifierRecorded,
    commitment_inserted: commitmentInserted,
  };
  const outPath = path.join(REPO_ROOT, "deployments", "pool-spend-result.json");
  fs.writeFileSync(outPath, JSON.stringify(result) + "\n");
  console.log(
    `\nverified: transact accepted the real Groth16 proof on chain; wrote ${outPath}`,
  );

  await shutdownEngine();
}

main()
  .then(() => process.exit(0))
  .catch(async (err) => {
    console.error("\npool-spend.ts failed:", err);
    try {
      await shutdownEngine();
    } catch {
      /* ignore */
    }
    process.exit(1);
  });
