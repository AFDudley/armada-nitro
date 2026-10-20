// ABOUTME: arn-2fd selective-disclosure acceptance, stage 1. Shields USDC from a test EOA into
// ABOUTME: a fresh wallet (H1), builds a real-proof depositFromNote unshield (H2+H4), and
// ABOUTME: precomputes a second, fresh note of the same wallet for the channel's payout (H5).

/**
 * `armada-disclosure-acceptance` job, stage 1.
 *
 * Mirrors env/gates/nitro-e2e/prepare.ts's shield + real-proof-unshield-to-the-adjudicator
 * pattern for a single channel (same lib/sdk calls), then adds what that gate does not need:
 * a second note of the SAME wallet, precomputed off chain (its note public key and its real
 * shield ciphertext), so stage 2 (script/DisclosureScenario.s.sol) can pay the channel's payout
 * (hop H5) by shielding to it, and stage 3 (finish.ts) can recognize and unshield it (hop H6).
 *
 * `npk = Poseidon(masterPublicKey, random)` (ShieldNote.getNotePublicKey) depends on neither a
 * value nor a token, so this note can be fully built now, before the channel exists, and handed
 * to stage 2 as the payout destination the disclosure statement will name.
 *
 * Writes, under DISCLOSURE_DIR (default /env/disclosure):
 *   wallet.json          {id, mnemonic, railgunAddress, masterPublicKey} -- stage 3 reloads this
 *                        wallet from the SAME engine database (this job's single container/shell;
 *                        no clearDatabase() in stage 3).
 *   deposits.json        {channelId, channelNonce, amount, calldata} -- script/DisclosureScenario
 *                        .s.sol's depositFromNote call (H2+H4).
 *   payout-shield.json   {npk, random, shieldPrivateKey, ciphertext, amount} -- the fresh note
 *                        stage 2's SHIELD allocation pays (H5); ciphertext is ABI-compatible with
 *                        src/armada/IArmadaPool.sol's ShieldCiphertext.
 *   package.json         the hop H1 evidence (EOA, npk1, random1, shield tx hash and amounts) --
 *                        stage 3 extends this file into the final disclosure package.
 *
 * Run via `npx hardhat run --network hub` from /src/armada-poc (copied to
 * scripts/gates/disclosure-prepare.ts there first, same as nitro-e2e's prepare.ts --
 * see docker-compose-armada-disclosure-acceptance.yml).
 */

import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

import { initializeEngine, clearDatabase, getEngine } from "../../lib/sdk/init";
import {
  createWallet,
  decodeAddress,
  DEFAULT_ENCRYPTION_KEY,
} from "../../lib/sdk/wallet";
import {
  initializeProver,
  createTransactionBatch,
  addUnshieldOutput,
  generateProvedTransactions,
} from "../../lib/sdk/prover";
import {
  createShieldRequest,
  generateShieldPrivateKey,
} from "../../lib/sdk/shield";
import {
  loadNetworkIntoEngine,
  scanWalletBalances,
} from "../../lib/sdk/network";
import { getSpendableBalance } from "../../lib/sdk/transfer";
import { getChainById, getRpcUrl } from "../../lib/sdk/chain-config";

import {
  TXIDVersion,
  POI,
  POINodeInterface,
  RailgunWallet,
  ShieldNoteERC20,
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
const CHALLENGE_DURATION = Number(process.env.CHALLENGE_DURATION || "30");
const SCAN_TIMEOUT_MS = 60_000;

// 150 USDC gross shield (nets ~149.25 after the pool's 50bps shield fee), 100 USDC of which
// funds the channel; the rest covers the fee and leaves headroom.
const SHIELD_AMOUNT = ethers.parseUnits("150", 6);
const DEPOSIT_AMOUNT = ethers.parseUnits("100", 6);
// The channel's final payout to the user (deposit + the hub's yield contribution, see
// script/DisclosureScenario.s.sol's HUB_FUNDS) -- used only to size the payout note's local
// placeholder value (ShieldNote's constructor wants a nonzero value; the real, on-chain value
// comes from the adjudicator's allocation amount, independent of this).
const PAYOUT_AMOUNT = ethers.parseUnits("120", 6);

const ADJUDICATOR_ABI = [
  "function depositBinding(bytes32 channelId, uint256 expectedHeld) view returns (bytes32)",
  "function depositFromNote(bytes32 channelId, uint256 expectedHeld, tuple(tuple(tuple(uint256 x, uint256 y) a, tuple(uint256[2] x, uint256[2] y) b, tuple(uint256 x, uint256 y) c) proof, bytes32 merkleRoot, bytes32[] nullifiers, bytes32[] commitments, tuple(uint16 treeNumber, uint72 minGasPrice, uint8 unshield, uint64 chainID, address adaptContract, bytes32 adaptParams, tuple(bytes32[4] ciphertext, bytes32 blindedSenderViewingKey, bytes32 blindedReceiverViewingKey, bytes annotationData, bytes memo)[] commitmentCiphertext) boundParams, tuple(bytes32 npk, tuple(uint8 tokenType, address tokenAddress, uint256 tokenSubID) token, uint120 value) unshieldPreimage)[] transactions) returns ()",
];

const EVENTS_ABI = [
  "event Shield(uint256 treeNumber, uint256 startPosition, tuple(bytes32 npk, tuple(uint8 tokenType, address tokenAddress, uint256 tokenSubID) token, uint120 value)[] commitments, tuple(bytes32[3] encryptedBundle, bytes32 shieldKey)[] shieldCiphertext, uint256[] fees)",
];
const eventsInterface = new ethers.Interface(EVENTS_ABI);

/** Ported from env/gates/nitro-e2e/prepare.ts (private to that file). */
function normalizeTransactionForAdjudicator(
  tx: unknown,
  chainId: number,
): unknown {
  const toBigInt = (v: unknown): bigint => {
    if (v == null) return 0n;
    if (typeof v === "bigint") return v;
    if (typeof v === "number" || typeof v === "string") return BigInt(v);
    return 0n;
  };
  const toHex = (v: unknown): string => {
    if (v == null) return ethers.ZeroHash;
    if (typeof v === "string" && v.startsWith("0x")) return v;
    try {
      return ethers.hexlify(v as ethers.BytesLike);
    } catch {
      return ethers.ZeroHash;
    }
  };
  const t = tx as Record<string, unknown>;
  const bp = t.boundParams as Record<string, unknown> | undefined;
  const rawCiphertext = (bp?.commitmentCiphertext ?? []) as Array<
    Record<string, unknown> | null | undefined
  >;
  const defaultCiphertext: [string, string, string, string] = [
    ethers.ZeroHash,
    ethers.ZeroHash,
    ethers.ZeroHash,
    ethers.ZeroHash,
  ];
  const commitmentCiphertext = rawCiphertext
    .filter((c): c is Record<string, unknown> => c != null)
    .map((c) => {
      const ct = c.ciphertext as string[] | undefined;
      const arr =
        Array.isArray(ct) && ct.length >= 4
          ? ([ct[0], ct[1], ct[2], ct[3]] as [string, string, string, string])
          : defaultCiphertext;
      return {
        ciphertext: arr,
        blindedSenderViewingKey: (c.blindedSenderViewingKey ??
          ethers.ZeroHash) as string,
        blindedReceiverViewingKey: (c.blindedReceiverViewingKey ??
          ethers.ZeroHash) as string,
        annotationData: (c.annotationData ?? "0x") as string,
        memo: (c.memo ?? "0x") as string,
      };
    });

  const up = t.unshieldPreimage as Record<string, unknown> | undefined;
  const token = (up?.token ?? {}) as Record<string, unknown>;
  const unshieldPreimage = {
    npk: toHex(up?.npk) || ethers.ZeroHash,
    token: {
      tokenType: Number(token.tokenType ?? 0),
      tokenAddress: (token.tokenAddress != null
        ? String(token.tokenAddress)
        : ethers.ZeroAddress) as string,
      tokenSubID: toBigInt(token.tokenSubID),
    },
    value: toBigInt(up?.value),
  };

  const proof = t.proof as Record<string, unknown> | undefined;
  const pa = (proof?.a ?? {}) as Record<string, unknown>;
  const pb = (proof?.b ?? {}) as Record<string, unknown>;
  const pc = (proof?.c ?? {}) as Record<string, unknown>;
  const pbx = pb.x as unknown[] | undefined;
  const pby = pb.y as unknown[] | undefined;
  const snarkProof = {
    a: { x: toBigInt(pa.x), y: toBigInt(pa.y) },
    b: {
      x: [toBigInt(pbx?.[0]), toBigInt(pbx?.[1])] as [bigint, bigint],
      y: [toBigInt(pby?.[0]), toBigInt(pby?.[1])] as [bigint, bigint],
    },
    c: { x: toBigInt(pc.x), y: toBigInt(pc.y) },
  };

  return {
    proof: snarkProof,
    merkleRoot: toHex(t.merkleRoot) || ethers.ZeroHash,
    nullifiers: ((t.nullifiers ?? []) as unknown[]).map(
      (n) => toHex(n) || ethers.ZeroHash,
    ) as string[],
    commitments: ((t.commitments ?? []) as unknown[]).map(
      (c) => toHex(c) || ethers.ZeroHash,
    ) as string[],
    boundParams: {
      treeNumber: Number(bp?.treeNumber ?? 0),
      minGasPrice: toBigInt(bp?.minGasPrice),
      unshield: Number(bp?.unshield ?? 1),
      chainID: toBigInt(bp?.chainID) || BigInt(chainId),
      adaptContract: (bp?.adaptContract != null
        ? String(bp.adaptContract)
        : ethers.ZeroAddress) as string,
      adaptParams: toHex(bp?.adaptParams) || ethers.ZeroHash,
      commitmentCiphertext,
    },
    unshieldPreimage,
  };
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

function decodeShieldEvents(
  receipt: ethers.TransactionReceipt,
): ethers.LogDescription[] {
  const out: ethers.LogDescription[] = [];
  for (const log of receipt.logs) {
    try {
      const parsed = eventsInterface.parseLog({
        topics: log.topics,
        data: log.data,
      });
      if (parsed && parsed.name === "Shield") out.push(parsed);
    } catch {
      /* not a Shield event -- e.g. ERC20 Transfer/Approval in the same receipt */
    }
  }
  return out;
}

async function main() {
  console.log("=".repeat(60));
  console.log(
    "  armada-disclosure-acceptance: stage 1 (shield + deposit build)",
  );
  console.log("=".repeat(60));

  const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, "utf-8"));
  const poolAddress: string = manifest.armada.pool;
  const usdcAddress: string = manifest.armada.usdc;
  const deployBlock: number = manifest.armada.deployBlock ?? 0;
  const adjudicatorAddress: string = manifest.armadaNitro.adjudicator;
  const consensusApp: string = manifest.armadaNitro.consensusApp;
  const custodian: string = manifest.armadaNitro.hubCustodian;
  const testAccounts: Array<{ address: string }> = manifest.testAccounts;
  if (!testAccounts || testAccounts.length < 2) {
    throw new Error(
      "need at least two testAccounts in the manifest (funding.py funds anvil indices 1-4)",
    );
  }
  const eoa1Address = testAccounts[0].address; // H1: shields
  const eoa2Address = testAccounts[1].address; // H6: receives the unshield

  const signers = await ethers.getSigners();
  const eoa1 = signers.find(
    (s) => s.address.toLowerCase() === eoa1Address.toLowerCase(),
  );
  if (!eoa1) {
    throw new Error(
      `test account ${eoa1Address} not found among hub network signers`,
    );
  }

  const privacyPool = await ethers.getContractAt("PrivacyPool", poolAddress);
  const usdc = await ethers.getContractAt("MockUSDCV2", usdcAddress);
  const adjudicatorRead = new ethers.Contract(
    adjudicatorAddress,
    ADJUDICATOR_ABI,
    ethers.provider,
  );
  const depositIface = new ethers.Interface(ADJUDICATOR_ABI);

  clearDatabase();
  await initializeEngine("disclosure");
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

  // ═══════════════════════ wallet W (the shielding wallet, one for the whole chain) ═══════════════════════
  const walletInfo = await createWallet(DEFAULT_ENCRYPTION_KEY);
  const engine = getEngine();
  const wallet = engine.wallets[walletInfo.id] as unknown as RailgunWallet;
  const { masterPublicKey, viewingPublicKey } = decodeAddress(
    walletInfo.railgunAddress,
  );
  console.log(
    `wallet W: ${walletInfo.railgunAddress} masterPublicKey=${masterPublicKey}`,
  );

  // ═══════════════════════ H1: shield 150 USDC from EOA1 ═══════════════════════
  console.log("\n--- H1: shield 150 USDC ---");
  const shieldFeeBps: bigint = await privacyPool.shieldFee();
  const shieldPrivateKey1 = generateShieldPrivateKey();
  const { shieldRequest: shieldRequest1 } = await createShieldRequest(
    {
      railgunAddress: walletInfo.railgunAddress,
      amount: SHIELD_AMOUNT,
      tokenAddress: usdcAddress,
    },
    shieldPrivateKey1,
  );
  await (await usdc.connect(eoa1).approve(poolAddress, SHIELD_AMOUNT)).wait();
  const shieldReceipt = await (
    await privacyPool.connect(eoa1).shield([shieldRequest1], ethers.ZeroAddress)
  ).wait();
  console.log(`H1 shield tx ${shieldReceipt!.hash}`);
  const shieldEvents = decodeShieldEvents(shieldReceipt);
  if (shieldEvents.length !== 1)
    throw new Error(`expected 1 Shield event, saw ${shieldEvents.length}`);
  const npk1 = shieldEvents[0].args.commitments[0].npk as string;
  const shieldNoteValue = BigInt(shieldEvents[0].args.commitments[0].value);
  console.log(
    `H1 Shield event: npk1=${npk1} value=${ethers.formatUnits(shieldNoteValue, 6)} USDC`,
  );

  await waitForBalance(
    walletInfo.id,
    chain,
    wallet,
    usdcAddress,
    DEPOSIT_AMOUNT,
    SCAN_TIMEOUT_MS,
  );
  console.log(
    `wallet W spendable: >= ${ethers.formatUnits(DEPOSIT_AMOUNT, 6)} USDC`,
  );

  // ═══════════════════════ H2 + H4: real-proof depositFromNote ═══════════════════════
  console.log("\n--- H2+H4: build depositFromNote (real proof) ---");
  const channelNonce = ethers.toBigInt(ethers.hexlify(ethers.randomBytes(8))); // uint64
  const participants = [eoa1.address, custodian];
  const channelId = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["address[]", "uint64", "address", "uint48"],
      [participants, channelNonce, consensusApp, CHALLENGE_DURATION],
    ),
  );
  const expectedHeld = 0n;
  const adaptParams: string = await adjudicatorRead.depositBinding(
    channelId,
    expectedHeld,
  );

  const batch = createTransactionBatch(chain);
  addUnshieldOutput(batch, adjudicatorAddress, DEPOSIT_AMOUNT, usdcAddress);
  batch.setAdaptID({ contract: adjudicatorAddress, parameters: adaptParams });

  const proofStart = Date.now();
  const transactions = await generateProvedTransactions(
    batch,
    wallet,
    TXIDVersion.V2_PoseidonMerkle,
    DEFAULT_ENCRYPTION_KEY,
    () => process.stdout.write("."),
  );
  console.log(`\nproof time ${Date.now() - proofStart}ms`);
  if (!transactions.length)
    throw new Error("SDK returned no proved transactions");
  const normalized = normalizeTransactionForAdjudicator(
    transactions[0],
    chain.id,
  );
  const calldata = depositIface.encodeFunctionData("depositFromNote", [
    channelId,
    expectedHeld,
    [normalized],
  ]);

  // ═══════════════════════ H5 precompute: a fresh note of wallet W for the channel's payout ═══════════════════════
  console.log("\n--- H5 precompute: payout note of the same wallet ---");
  const shieldPrivateKey2 = generateShieldPrivateKey();
  const payoutNote = new ShieldNoteERC20(
    masterPublicKey,
    ethers.hexlify(ethers.randomBytes(16)).slice(2),
    PAYOUT_AMOUNT,
    usdcAddress,
  );
  const payoutShieldRequest = await payoutNote.serialize(
    ethers.getBytes(`0x${shieldPrivateKey2}`),
    viewingPublicKey,
  );
  const npk2 = ethers.hexlify(ethers.toBeArray(payoutNote.notePublicKey));
  const npk2Padded = ethers.zeroPadValue(npk2, 32);
  console.log(`payout npk2=${npk2Padded} (random=${payoutNote.random})`);

  // ═══════════════════════ write artifacts ═══════════════════════
  fs.mkdirSync(DISCLOSURE_DIR, { recursive: true });
  fs.writeFileSync(
    path.join(DISCLOSURE_DIR, "wallet.json"),
    JSON.stringify(
      {
        id: walletInfo.id,
        mnemonic: walletInfo.mnemonic,
        railgunAddress: walletInfo.railgunAddress,
        masterPublicKey: masterPublicKey.toString(),
      },
      null,
      2,
    ),
  );
  fs.writeFileSync(
    path.join(DISCLOSURE_DIR, "deposits.json"),
    JSON.stringify(
      {
        channelId,
        channelNonce: channelNonce.toString(),
        amount: DEPOSIT_AMOUNT.toString(),
        calldata,
        user: eoa1.address,
        custodian,
        consensusApp,
        challengeDuration: CHALLENGE_DURATION,
      },
      null,
      2,
    ),
  );
  fs.writeFileSync(
    path.join(DISCLOSURE_DIR, "payout-shield.json"),
    JSON.stringify(
      {
        npk: npk2Padded,
        random: payoutNote.random,
        shieldPrivateKey: shieldPrivateKey2,
        ciphertext: payoutShieldRequest.ciphertext,
        amount: PAYOUT_AMOUNT.toString(),
      },
      null,
      2,
    ),
  );
  fs.writeFileSync(
    path.join(DISCLOSURE_DIR, "package.json"),
    JSON.stringify(
      {
        eoa1: eoa1.address,
        eoa2: eoa2Address,
        masterPublicKey: masterPublicKey.toString(),
        walletRailgunAddress: walletInfo.railgunAddress,
        h1: {
          shieldTxHash: shieldReceipt!.hash,
          npk1,
          shieldAmountGross: SHIELD_AMOUNT.toString(),
          shieldNoteValue: shieldNoteValue.toString(),
          shieldFeeBps: shieldFeeBps.toString(),
        },
      },
      null,
      2,
    ),
  );
  console.log(
    `\nwrote ${DISCLOSURE_DIR}/{wallet,deposits,payout-shield,package}.json`,
  );
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("\ndisclosure prepare.ts failed:", err);
    process.exit(1);
  });
