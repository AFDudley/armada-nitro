// ABOUTME: arn-2fd selective-disclosure acceptance, stage 3. Confirms the channel's SHIELD
// ABOUTME: payout (H5) really shields wallet W's precomputed npk2, unshields it to a second test
// ABOUTME: EOA (H6), and writes the final disclosure package with the required summary fields.

/**
 * `armada-disclosure-acceptance` job, stage 3.
 *
 * Reuses stage 1's SAME engine database (this job's one container/shell; no clearDatabase()
 * here) and reloads wallet W from disclosure/wallet.json. Confirms the conclude transaction's
 * Shield event really shielded stage 1's precomputed npk2 (hop H5, checked here rather than
 * assumed), waits for wallet W to recognize the new note, then unshields it to EOA2 with a real
 * proof (hop H6, same lib/sdk calls as env/gates/pool-e2e/pool-e2e.ts's step 3).
 *
 * Reads, under DISCLOSURE_DIR (default /env/disclosure): wallet.json, deposits.json,
 * payout-shield.json, package.json (stage 1), channel-states.json (stage 2, script/
 * DisclosureScenario.s.sol). CONCLUDE_TX_HASH (env, required) names the conclude transaction
 * whose Shield event this checks.
 *
 * Writes DISCLOSURE_DIR/package.json (overwrites stage 1's partial version) with every hop's
 * evidence and the five summary fields stack/scripts/armada-disclosure-acceptance.py reads:
 * hops_ok, eoa2_usdc_delta, eoa_distinct, payout_note_owned, package_path (filled in by the
 * python script once it copies this file out of the deployment's /env volume).
 */

import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

import { initializeEngine, getEngine } from "../../lib/sdk/init";
import { DEFAULT_ENCRYPTION_KEY } from "../../lib/sdk/wallet";
import {
  loadNetworkIntoEngine,
  scanWalletBalances,
} from "../../lib/sdk/network";
import { createUnshield, getSpendableBalance } from "../../lib/sdk/transfer";
import { getChainById, getRpcUrl } from "../../lib/sdk/chain-config";

import {
  POI,
  POINodeInterface,
  RailgunWallet,
} from "@railgun-community/engine";
import { ChainType, Chain } from "@railgun-community/shared-models";

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

const MANIFEST_PATH = process.env.MANIFEST_PATH || "/env/manifest.json";
const DISCLOSURE_DIR = process.env.DISCLOSURE_DIR || "/env/disclosure";
const CONCLUDE_TX_HASH = process.env.CONCLUDE_TX_HASH;
const SCAN_TIMEOUT_MS = 90_000;

const EVENTS_ABI = [
  "event Shield(uint256 treeNumber, uint256 startPosition, tuple(bytes32 npk, tuple(uint8 tokenType, address tokenAddress, uint256 tokenSubID) token, uint120 value)[] commitments, tuple(bytes32[3] encryptedBundle, bytes32 shieldKey)[] shieldCiphertext, uint256[] fees)",
  "event Unshield(address to, tuple(uint8 tokenType, address tokenAddress, uint256 tokenSubID) token, uint256 amount, uint256 fee)",
];
const eventsInterface = new ethers.Interface(EVENTS_ABI);

function decodeEvents(
  receipt: ethers.TransactionReceipt,
  name: string,
): ethers.LogDescription[] {
  const out: ethers.LogDescription[] = [];
  for (const log of receipt.logs) {
    try {
      const parsed = eventsInterface.parseLog({
        topics: log.topics,
        data: log.data,
      });
      if (parsed && parsed.name === name) out.push(parsed);
    } catch {
      /* not one of our two events */
    }
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
  console.log("=".repeat(60));
  console.log(
    "  armada-disclosure-acceptance: stage 3 (payout check + unshield to EOA2)",
  );
  console.log("=".repeat(60));

  if (!CONCLUDE_TX_HASH) throw new Error("CONCLUDE_TX_HASH is required");

  const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, "utf-8"));
  const poolAddress: string = manifest.armada.pool;
  const usdcAddress: string = manifest.armada.usdc;
  const deployBlock: number = manifest.armada.deployBlock ?? 0;

  const walletInfo = JSON.parse(
    fs.readFileSync(path.join(DISCLOSURE_DIR, "wallet.json"), "utf-8"),
  );
  const deposits = JSON.parse(
    fs.readFileSync(path.join(DISCLOSURE_DIR, "deposits.json"), "utf-8"),
  );
  const payoutShield = JSON.parse(
    fs.readFileSync(path.join(DISCLOSURE_DIR, "payout-shield.json"), "utf-8"),
  );
  const pkg = JSON.parse(
    fs.readFileSync(path.join(DISCLOSURE_DIR, "package.json"), "utf-8"),
  );
  const channelStates = JSON.parse(
    fs.readFileSync(path.join(DISCLOSURE_DIR, "channel-states.json"), "utf-8"),
  );

  const eoa1Address: string = pkg.eoa1;
  const eoa2Address: string = pkg.eoa2;
  const payoutNpk: string = payoutShield.npk;

  const signers = await ethers.getSigners();
  const broadcaster = signers[0]; // any funded signer may submit the unshield calldata
  const usdc = await ethers.getContractAt("MockUSDCV2", usdcAddress);

  // ═══════════════════════ H5 check: the conclude tx really shielded payoutNpk ═══════════════════════
  console.log("\n--- H5 check: conclude tx's Shield event ---");
  const concludeReceipt =
    await ethers.provider.getTransactionReceipt(CONCLUDE_TX_HASH);
  if (!concludeReceipt)
    throw new Error(`no receipt for conclude tx ${CONCLUDE_TX_HASH}`);
  const shieldEvents = decodeEvents(concludeReceipt, "Shield");
  let payoutShieldValue: bigint | undefined;
  for (const ev of shieldEvents) {
    for (const note of ev.args.commitments) {
      if ((note.npk as string).toLowerCase() === payoutNpk.toLowerCase()) {
        payoutShieldValue = BigInt(note.value);
      }
    }
  }
  const payoutNoteOwned =
    payoutShieldValue !== undefined && payoutShieldValue > 0n;
  if (!payoutNoteOwned) {
    throw new Error(
      `conclude tx ${CONCLUDE_TX_HASH} has no Shield commitment for npk2=${payoutNpk} ` +
        `(computed as Poseidon(masterPublicKey, random2) in stage 1)`,
    );
  }
  console.log(
    `H5 confirmed: Shield event pays npk2=${payoutNpk} value=${ethers.formatUnits(payoutShieldValue!, 6)} USDC`,
  );

  // ═══════════════════════ reload wallet W, wait for the payout note ═══════════════════════
  await initializeEngine("disclosure"); // same db as stage 1 -- no clearDatabase()
  const engine = getEngine();
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

  let wallet: RailgunWallet;
  try {
    wallet = (await engine.loadExistingWallet(
      walletInfo.id,
      DEFAULT_ENCRYPTION_KEY,
    )) as RailgunWallet;
  } catch {
    wallet = (await engine.createWalletFromMnemonic(
      DEFAULT_ENCRYPTION_KEY,
      walletInfo.mnemonic,
      0,
      undefined,
    )) as RailgunWallet;
  }

  const spendable = await waitForBalance(
    walletInfo.id,
    chain,
    wallet,
    usdcAddress,
    payoutShieldValue!,
    SCAN_TIMEOUT_MS,
  );
  console.log(
    `wallet W recognizes the payout note: spendable ${ethers.formatUnits(spendable, 6)} USDC`,
  );

  // ═══════════════════════ H6: unshield the payout note to EOA2 ═══════════════════════
  console.log("\n--- H6: unshield to EOA2 ---");
  const eoa2BalanceBefore: bigint = await usdc.balanceOf(eoa2Address);
  const unshieldResult = await createUnshield({
    wallet,
    chain,
    tokenAddress: usdcAddress,
    recipientAddress: eoa2Address,
    amount: payoutShieldValue!,
    encryptionKey: DEFAULT_ENCRYPTION_KEY,
    progressCallback: () => process.stdout.write("."),
  });
  console.log("");
  const unshieldTx = await broadcaster.sendTransaction({
    to: unshieldResult.contractTransaction.to,
    data: unshieldResult.contractTransaction.data,
  });
  const unshieldReceipt = await unshieldTx.wait();
  console.log(`H6 unshield tx ${unshieldReceipt!.hash}`);
  const unshieldEvents = decodeEvents(unshieldReceipt, "Unshield");
  if (unshieldEvents.length !== 1)
    throw new Error(`expected 1 Unshield event, saw ${unshieldEvents.length}`);
  const unshieldEvent = unshieldEvents[0];
  if (
    (unshieldEvent.args.to as string).toLowerCase() !==
    eoa2Address.toLowerCase()
  ) {
    throw new Error(
      `Unshield event recipient ${unshieldEvent.args.to} != expected ${eoa2Address}`,
    );
  }
  const eoa2BalanceAfter: bigint = await usdc.balanceOf(eoa2Address);
  const eoa2UsdcDelta = eoa2BalanceAfter - eoa2BalanceBefore;
  if (eoa2UsdcDelta <= 0n)
    throw new Error(
      `EOA2's USDC balance did not increase (delta=${eoa2UsdcDelta})`,
    );
  console.log(
    `H6 confirmed: EOA2 (${eoa2Address}) gained ${ethers.formatUnits(eoa2UsdcDelta, 6)} USDC`,
  );

  const eoaDistinct = eoa1Address.toLowerCase() !== eoa2Address.toLowerCase();
  const h7Ok =
    channelStates.state0.sigs.length === 2 &&
    channelStates.state1.sigs.length === 2 &&
    channelStates.state1.userAmount ===
      String(channelStates.depositAmount + channelStates.hubYield);
  const hopsOk =
    Boolean(pkg.h1?.shieldTxHash) &&
    Boolean(deposits.calldata) &&
    h7Ok &&
    payoutNoteOwned &&
    eoaDistinct;

  const finalPackage = {
    ...pkg,
    h2_h4: {
      channelId: deposits.channelId,
      channelNonce: deposits.channelNonce,
      depositAmount: deposits.amount,
      depositCalldataHash: ethers.keccak256(deposits.calldata),
    },
    h7: channelStates,
    h5: {
      concludeTxHash: CONCLUDE_TX_HASH,
      payoutNpk,
      payoutRandom: payoutShield.random,
      payoutShieldValue: payoutShieldValue!.toString(),
    },
    h6: {
      unshieldTxHash: unshieldReceipt!.hash,
      eoa2: eoa2Address,
      eoa2UsdcDelta: eoa2UsdcDelta.toString(),
    },
    hops_ok: hopsOk,
    eoa2_usdc_delta: Number(eoa2UsdcDelta),
    eoa_distinct: eoaDistinct,
    payout_note_owned: payoutNoteOwned,
  };
  fs.writeFileSync(
    path.join(DISCLOSURE_DIR, "package.json"),
    JSON.stringify(finalPackage, null, 2),
  );
  console.log(`\nwrote final package to ${DISCLOSURE_DIR}/package.json`);
  console.log(
    JSON.stringify({
      hops_ok: hopsOk,
      eoa2_usdc_delta: Number(eoa2UsdcDelta),
      eoa_distinct: eoaDistinct,
      payout_note_owned: payoutNoteOwned,
    }),
  );
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("\ndisclosure finish.ts failed:", err);
    process.exit(1);
  });
