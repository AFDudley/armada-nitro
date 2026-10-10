// ABOUTME: Stage 1 of the armada-watchtower-e2e gate. Shields USDC from a test account, then
// ABOUTME: builds a real-proof unshield to the adjudicator for two channels (one per scenario).

/**
 * `armada-watchtower-e2e` gate, stage 1 (E15). A parameterized sibling of
 * env/gates/nitro-e2e/prepare.ts: same real-proof deposit flow (shield, then a Groth16-proved
 * `depositFromNote` unshield bound to the adjudicator), but the deposit amount is the total
 * channel funding this gate's two scenarios need (`DEPOSIT_AMOUNT_UNITS`, base units) instead of
 * nitro-e2e's fixed 100 USDC -- here the user funds the whole channel (no separate hub top-up;
 * see script/WatchtowerScenario.s.sol's header for why the hub needs no stock of its own).
 *
 * CHANNEL_COUNT is fixed at 2 -- one channel per scenario (A, B); scenario B needs its own
 * channel because scenario A's already finalized and emptied by the time B runs.
 *
 * Writes deposits.json: per channel {channelId, channelNonce, amount, calldata, proofTimeMs},
 * same shape as nitro-e2e's (channelNonce is required so WatchtowerScenario.s.sol can
 * reconstruct the exact FixedPart whose channelId the proof is bound to).
 *
 * Run via `npx hardhat run --network hub` from /src/armada-poc (this file is copied to
 * scripts/gates/prepare.ts there first, same as env/gates/nitro-e2e/prepare.ts).
 */

import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

import {
  initializeEngine,
  shutdownEngine,
  clearDatabase,
  getEngine,
} from "../../lib/sdk/init";
import { createWallet, DEFAULT_ENCRYPTION_KEY } from "../../lib/sdk/wallet";
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
} from "@railgun-community/engine";
import { ChainType, Chain } from "@railgun-community/shared-models";

// Same stub as env/gates/nitro-e2e/prepare.ts -- POI is not part of this environment.
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
const OUTPUT_PATH =
  process.env.DEPOSITS_OUTPUT || "/env/watchtower-e2e/deposits.json";
const CHALLENGE_DURATION = Number(process.env.CHALLENGE_DURATION || "30");
const CHANNEL_COUNT = 2;

const DEPOSIT_AMOUNT = BigInt(process.env.DEPOSIT_AMOUNT_UNITS || "2500000"); // base units; the user funds the whole channel (see script/WatchtowerScenario.s.sol).
const SHIELD_AMOUNT = DEPOSIT_AMOUNT * 2n; // gross; plenty of headroom after the pool's shield fee.
const SCAN_TIMEOUT_MS = 60_000;

// Minimal ABI for the two adjudicator calls this script needs, identical to
// env/gates/nitro-e2e/prepare.ts's ADJUDICATOR_ABI.
const ADJUDICATOR_ABI = [
  "function depositBinding(bytes32 channelId, uint256 expectedHeld) view returns (bytes32)",
  "function depositFromNote(bytes32 channelId, uint256 expectedHeld, tuple(tuple(tuple(uint256 x, uint256 y) a, tuple(uint256[2] x, uint256[2] y) b, tuple(uint256 x, uint256 y) c) proof, bytes32 merkleRoot, bytes32[] nullifiers, bytes32[] commitments, tuple(uint16 treeNumber, uint72 minGasPrice, uint8 unshield, uint64 chainID, address adaptContract, bytes32 adaptParams, tuple(bytes32[4] ciphertext, bytes32 blindedSenderViewingKey, bytes32 blindedReceiverViewingKey, bytes annotationData, bytes memo)[] commitmentCiphertext) boundParams, tuple(bytes32 npk, tuple(uint8 tokenType, address tokenAddress, uint256 tokenSubID) token, uint120 value) unshieldPreimage)[] transactions) returns ()",
];

/** Normalize the proved TransactionStructV2 into the tuple the adjudicator ABI expects. Ported
 * from env/gates/nitro-e2e/prepare.ts (itself ported from lib/sdk/yield.ts). */
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

async function main() {
  const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, "utf-8"));
  const poolAddress: string = manifest.armada.pool;
  const usdcAddress: string = manifest.armada.usdc;
  const deployBlock: number = manifest.armada.deployBlock ?? 0;
  const adjudicatorAddress: string = manifest.armadaNitro.adjudicator;
  const consensusApp: string = manifest.armadaNitro.consensusApp;
  const hub: string = manifest.testAccounts[1].address;
  const testAccountAddress: string = manifest.testAccounts[0].address;

  console.log(
    `pool=${poolAddress} usdc=${usdcAddress} adjudicator=${adjudicatorAddress}`,
  );
  console.log(
    `consensusApp=${consensusApp} hub=${hub} testAccount=${testAccountAddress}`,
  );
  console.log(
    `channels=${CHANNEL_COUNT} challengeDuration=${CHALLENGE_DURATION} depositAmount=${DEPOSIT_AMOUNT}`,
  );

  const signers = await ethers.getSigners();
  const user = signers.find(
    (s) => s.address.toLowerCase() === testAccountAddress.toLowerCase(),
  );
  if (!user) {
    throw new Error(
      `test account ${testAccountAddress} not found among hub network signers (mnemonic-derived); ` +
        `expected it at signers[1] (anvil mnemonic index 1)`,
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
  await initializeEngine("watchtowere2e");
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

  const deposits: Array<{
    channelId: string;
    channelNonce: string;
    amount: string;
    calldata: string;
    proofTimeMs: number;
  }> = [];

  for (let i = 0; i < CHANNEL_COUNT; i++) {
    const walletInfo = await createWallet(DEFAULT_ENCRYPTION_KEY);
    const engine = getEngine();
    const wallet = engine.wallets[walletInfo.id] as unknown as RailgunWallet;
    console.log(
      `\nchannel ${i}: shielding wallet ${walletInfo.railgunAddress}`,
    );

    const shieldPrivateKey = generateShieldPrivateKey();
    const { shieldRequest } = await createShieldRequest(
      {
        railgunAddress: walletInfo.railgunAddress,
        amount: SHIELD_AMOUNT,
        tokenAddress: usdcAddress,
      },
      shieldPrivateKey,
    );
    await (await usdc.connect(user).approve(poolAddress, SHIELD_AMOUNT)).wait();
    const shieldTx = await privacyPool
      .connect(user)
      .shield([shieldRequest], ethers.ZeroAddress);
    const shieldReceipt = await shieldTx.wait();
    console.log(`channel ${i}: shield tx ${shieldReceipt!.hash}`);

    const spendable = await waitForBalance(
      walletInfo.id,
      chain,
      wallet,
      usdcAddress,
      DEPOSIT_AMOUNT,
      SCAN_TIMEOUT_MS,
    );
    console.log(
      `channel ${i}: spendable after shield ${spendable.toString()} base units`,
    );

    const channelNonce = ethers.toBigInt(ethers.hexlify(ethers.randomBytes(8))); // uint64
    const participants = [user.address, hub];
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
      () => process.stdout.write(`.`),
    );
    const proofTimeMs = Date.now() - proofStart;
    console.log(
      `\nchannel ${i}: channelId=${channelId} proof time=${proofTimeMs}ms`,
    );

    if (!transactions.length)
      throw new Error(`channel ${i}: SDK returned no proved transactions`);
    const normalized = normalizeTransactionForAdjudicator(
      transactions[0],
      chain.id,
    );
    const calldata = depositIface.encodeFunctionData("depositFromNote", [
      channelId,
      expectedHeld,
      [normalized],
    ]);

    deposits.push({
      channelId,
      channelNonce: channelNonce.toString(),
      amount: DEPOSIT_AMOUNT.toString(),
      calldata,
      proofTimeMs,
    });
  }

  fs.mkdirSync(path.dirname(OUTPUT_PATH), { recursive: true });
  fs.writeFileSync(
    OUTPUT_PATH,
    JSON.stringify(
      {
        network: manifest.network,
        pool: poolAddress,
        usdc: usdcAddress,
        adjudicator: adjudicatorAddress,
        consensusApp,
        hub,
        user: user.address,
        challengeDuration: CHALLENGE_DURATION,
        deposits,
      },
      null,
      2,
    ) + "\n",
  );
  console.log(`\nwrote ${OUTPUT_PATH}`);
  for (const d of deposits) {
    console.log(
      `  channel ${d.channelId}: amount=${d.amount} base units proofTimeMs=${d.proofTimeMs}`,
    );
  }

  await shutdownEngine();
}

main()
  .then(() => {
    process.exit(0);
  })
  .catch(async (err) => {
    console.error("\nprepare.ts failed:", err);
    try {
      await shutdownEngine();
    } catch {
      /* ignore */
    }
    process.exit(1);
  });
