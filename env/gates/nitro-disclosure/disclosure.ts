// ABOUTME: the selective-disclosure hop runner (arn-252). Executes hops H1-H7 as real
// transactions on the fixturenet, writes a disclosure package recording every transaction
// and event, and prints one JSON line with hops_ok, eoa2_usdc_delta, eoa_distinct,
// payout_note_owned, package_path.
//
// Run via `npx hardhat run` from /src/armada-poc (copied to scripts/gates/disclosure.ts),
// mirroring prepare.ts's engine + prover setup. Drives the actual hops:
//   H1  a test EOA shields USDC (pool.shield)
//   H2+H4 the note funds a hub channel (adjudicator.depositFromNote, real Groth16 proof)
//   H7  the wallet and the hub co-sign a channel state (user EOA key + a hub delegate key;
//       the delegate is authorized on the HubCustodian by one FROST-signed `execute` call --
//       the custodian's `isValidSignature` then accepts the delegate's plain ECDSA signature,
//       same as src/HubCustodian.sol's design: FROST authorizes cold operations, delegates
//       sign states)
//   H5  the channel pays a SHIELD payout to a fresh note of the same wallet
//       (adjudicator.transferAllAssets, which shields the note inside the adjudicator's
//       `_executeSingleAssetExit`)
//   H6  that note is unshielded to a second test EOA (pool.transact, a real Groth16 proof)

import { ethers } from "hardhat";
import type { Wallet as EthersWallet, HDNodeWallet, BytesLike } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { execFileSync } from "child_process";

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
  generateTransactCall,
} from "../../lib/sdk/prover";
import { createShieldRequest, generateShieldPrivateKey } from "../../lib/sdk/shield";
import { loadNetworkIntoEngine, scanWalletBalances } from "../../lib/sdk/network";
import { getChainById, getRpcUrl } from "../../lib/sdk/chain-config";
import { getSpendableBalance } from "../../lib/sdk/transfer";
import { TXIDVersion, RailgunWallet, POI, POINodeInterface } from "@railgun-community/engine";
import { ChainType, Chain } from "@railgun-community/shared-models";

// Same stub as scripts/capture/e2e-armada-circuits.ts -- POI is not part of this environment.
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
const PACKAGE_PATH = process.env.PACKAGE_PATH || "/env/nitro-disclosure/disclosure-package.json";
const KEYS_DIR = process.env.KEYS_DIR || "/env";
const FROST_SHARES_DIR = process.env.FROST_SHARES_DIR || "/env";
const FROST_SIGNER = process.env.FROST_SIGNER || "frost-signer";
const CHALLENGE_DURATION = Number(process.env.CHALLENGE_DURATION || "30");
const DEPOSIT_AMOUNT = ethers.parseUnits("100", 6); // channel deposit == channel payout (no hub cut)
const SHIELD_AMOUNT = ethers.parseUnits("150", 6); // nets >= DEPOSIT_AMOUNT after the pool's shield fee
const SCAN_TIMEOUT_MS = 60_000;

const OUTCOME_TUPLE =
  "tuple(address asset, tuple(uint8 assetType, bytes metadata) assetMetadata, tuple(bytes32 destination, uint256 amount, uint8 allocationType, bytes metadata)[] allocations)[]";

const ADJUDICATOR_ABI = [
  "function depositBinding(bytes32 channelId, uint256 expectedHeld) view returns (bytes32)",
  "function depositFromNote(bytes32 channelId, uint256 expectedHeld, tuple(tuple(tuple(uint256 x, uint256 y) a, tuple(uint256[2] x, uint256[2] y) b, tuple(uint256 x, uint256 y) c) proof, bytes32 merkleRoot, bytes32[] nullifiers, bytes32[] commitments, tuple(uint16 treeNumber, uint72 minGasPrice, uint8 unshield, uint64 chainID, address adaptContract, bytes32 adaptParams, tuple(bytes32[4] ciphertext, bytes32 blindedSenderViewKey, bytes32 blindedReceiverViewKey, bytes annotationData, bytes memo)[] commitmentCiphertext) boundParams, tuple(bytes32 npk, tuple(uint8 tokenType, address tokenAddress, uint256 tokenSubID) token, uint120 value) unshieldPreimage)[] transactions) returns ()",
  `function conclude(tuple(address[] participants, uint64 channelNonce, address appDefinition, uint48 challengeDuration) fixedPart, tuple(tuple(${OUTCOME_TUPLE} outcome, bytes appData, uint48 turnNum, bool isFinal) variablePart, tuple(uint8 v, bytes32 r, bytes32 s)[] sigs) candidate) returns ()`,
  `function transferAllAssets(bytes32 channelId, ${OUTCOME_TUPLE} outcome, bytes32 stateHash) returns ()`,
];

const CUSTODIAN_ABI = [
  "function nonce() view returns (uint256)",
  "function operationHash(uint256 nonce, address target, uint256 value, bytes data) view returns (bytes32)",
  "function execute(address target, uint256 value, bytes data, tuple(uint256 commitmentX, uint256 commitmentY, uint256 z) signature) returns (bytes memory)",
];

// Normalizes the SDK's proved transaction into the adjudicator's tuple shape (ported from
// env/gates/nitro-e2e/prepare.ts's normalizeTransactionForAdjudicator).
function normalizeTransactionForAdjudicator(tx: unknown, chainId: number): unknown {
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
      return ethers.hexlify(v as BytesLike);
    } catch {
      return ethers.ZeroHash;
    }
  };
  const t = tx as Record<string, unknown>;
  const bp = t.boundParams as Record<string, unknown> | undefined;
  const up = t.unshieldPreimage as Record<string, unknown> | undefined;
  const token = (up?.token ?? {}) as Record<string, unknown>;
  const proof = t.proof as Record<string, unknown> | undefined;
  const pa = (proof?.a ?? {}) as Record<string, unknown>;
  const pb = (proof?.b ?? {}) as Record<string, unknown>;
  const pc = (proof?.c ?? {}) as Record<string, unknown>;
  const pbx = pb.x as unknown[] | undefined;
  const pby = pb.y as unknown[] | undefined;
  const rawCiphertext = (bp?.commitmentCiphertext ?? []) as Array<Record<string, unknown> | null | undefined>;
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
        blindedSenderViewKey: (c.blindedSenderViewingKey ?? ethers.ZeroHash) as string,
        blindedReceiverViewKey: (c.blindedReceiverViewingKey ?? ethers.ZeroHash) as string,
        annotationData: (c.annotationData ?? "0x") as string,
        memo: (c.memo ?? "0x") as string,
      };
    });

  return {
    proof: {
      a: { x: toBigInt(pa.x), y: toBigInt(pa.y) },
      b: {
        x: [toBigInt(pbx?.[0]), toBigInt(pbx?.[1])] as [bigint, bigint],
        y: [toBigInt(pby?.[0]), toBigInt(pby?.[1])] as [bigint, bigint],
      },
      c: { x: toBigInt(pc.x), y: toBigInt(pc.y) },
    },
    merkleRoot: toHex(t.merkleRoot) || ethers.ZeroHash,
    nullifiers: ((t.nullifiers ?? []) as unknown[]).map((n) => toHex(n) || ethers.ZeroHash),
    commitments: ((t.commitments ?? []) as unknown[]).map((c) => toHex(c) || ethers.ZeroHash),
    boundParams: {
      treeNumber: Number(bp?.treeNumber ?? 0),
      minGasPrice: toBigInt(bp?.minGasPrice),
      unshield: Number(bp?.unshield ?? 1),
      chainID: toBigInt(bp?.chainID) || BigInt(chainId),
      adaptContract: (bp?.adaptContract != null ? String(bp.adaptContract) : ethers.ZeroAddress) as string,
      adaptParams: toHex(bp?.adaptParams) || ethers.ZeroHash,
      commitmentCiphertext,
    },
    unshieldPreimage: {
      npk: toHex(up?.npk) || ethers.ZeroHash,
      token: {
        tokenType: Number(token.tokenType ?? 0),
        tokenAddress: (token.tokenAddress != null ? String(token.tokenAddress) : ethers.ZeroAddress) as string,
        tokenSubID: toBigInt(token.tokenSubID),
      },
      value: toBigInt(up?.value),
    },
  };
}

async function waitForBalance(
  walletId: string,
  chain: Chain,
  wallet: RailgunWallet,
  tokenAddress: string,
  minAmount: bigint,
): Promise<bigint> {
  const start = Date.now();
  while (Date.now() - start < SCAN_TIMEOUT_MS) {
    await scanWalletBalances(walletId, chain);
    const bal = await getSpendableBalance(wallet, chain, tokenAddress);
    if (bal >= minAmount) return bal;
    await new Promise((r) => setTimeout(r, 3000));
  }
  throw new Error(`spendable balance didn't reach ${minAmount} within ${SCAN_TIMEOUT_MS / 1000}s`);
}

// Sign `digest` (raw 32 bytes, no prefix) the same way NitroUtils.recoverSigner expects:
// ecrecover(keccak256("\x19Ethereum Signed Message:\n32" + digest), v, r, s). ethers' own
// `signMessage` applies that exact EIP-191 prefix when given raw bytes (not a hex string).
async function signState(wallet: EthersWallet | HDNodeWallet, digest: string): Promise<{ v: number; r: string; s: string }> {
  const flat = await wallet.signMessage(ethers.getBytes(digest));
  const sig = ethers.Signature.from(flat);
  return { v: sig.v, r: sig.r, s: sig.s };
}

async function main() {
  const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, "utf-8") as string);
  const poolAddress: string = manifest.armada.pool;
  const usdcAddress: string = manifest.armada.usdc;
  const deployBlock: number = manifest.armada.deployBlock ?? 0;
  const adjudicatorAddress: string = manifest.armadaNitro.adjudicator;
  const consensusApp: string = manifest.armadaNitro.consensusApp;
  const custodianAddress: string = manifest.armadaNitro.hubCustodian;

  const testAccounts: Array<{ address: string; privateKeyFile: string }> = manifest.testAccounts || [];
  if (testAccounts.length < 2) {
    throw new Error("manifest has fewer than 2 testAccounts; need a second EOA for H6");
  }
  const eoa1 = testAccounts[0].address;
  const eoa2 = testAccounts[1].address;
  const eoa_distinct = eoa1.toLowerCase() !== eoa2.toLowerCase();

  const signers = await ethers.getSigners();
  const signer = signers.find((s) => s.address.toLowerCase() === eoa1.toLowerCase());
  if (!signer) throw new Error(`test account ${eoa1} not found among hub network signers`);
  const userKeyFile = path.join(KEYS_DIR, testAccounts[0].privateKeyFile);
  const userWallet = new ethers.Wallet(fs.readFileSync(userKeyFile, "utf-8").trim());

  const privacyPool = await ethers.getContractAt("PrivacyPool", poolAddress);
  const usdc = await ethers.getContractAt("MockUSDCV2", usdcAddress);
  const adjudicator = new ethers.Contract(adjudicatorAddress, ADJUDICATOR_ABI, ethers.provider);
  const custodian = new ethers.Contract(custodianAddress, CUSTODIAN_ABI, ethers.provider);

  clearDatabase();
  await initializeEngine("disclosure");
  const chain: Chain = getChainById(31337) ?? { type: ChainType.EVM, id: 31337 };
  const rpcUrl = getRpcUrl(chain);
  await loadNetworkIntoEngine(chain, poolAddress, ethers.ZeroAddress, rpcUrl, deployBlock);
  await initializeProver();

  // ---- H1: the test EOA shields USDC into a fresh note (npk1) ----
  const walletInfo = await createWallet(DEFAULT_ENCRYPTION_KEY);
  const engine = getEngine();
  const wallet = engine.wallets[walletInfo.id] as unknown as RailgunWallet;

  const { shieldRequest } = await createShieldRequest(
    { railgunAddress: walletInfo.railgunAddress, amount: SHIELD_AMOUNT, tokenAddress: usdcAddress },
    generateShieldPrivateKey(),
  );
  await (await usdc.connect(signer).approve(poolAddress, SHIELD_AMOUNT)).wait();
  const shieldTxn = await privacyPool.connect(signer).shield([shieldRequest], ethers.ZeroAddress);
  const shieldReceipt = await shieldTxn.wait();
  const npk1 = shieldRequest.preimage.npk as string;
  await waitForBalance(walletInfo.id, chain, wallet, usdcAddress, DEPOSIT_AMOUNT);

  // ---- H2 + H4: the note funds a hub channel via depositFromNote (real Groth16 proof) ----
  const channelNonce = ethers.toBigInt(ethers.hexlify(ethers.randomBytes(8)));
  const participants = [signer.address, custodianAddress];
  const channelId = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["address[]", "uint64", "address", "uint48"],
      [participants, channelNonce, consensusApp, CHALLENGE_DURATION],
    ),
  );
  const expectedHeld = 0n;
  const adaptParams: string = await adjudicator.depositBinding(channelId, expectedHeld);

  const batch = createTransactionBatch(chain);
  addUnshieldOutput(batch, adjudicatorAddress, DEPOSIT_AMOUNT, usdcAddress);
  batch.setAdaptID({ contract: adjudicatorAddress, parameters: adaptParams });
  const depositTxs = await generateProvedTransactions(
    batch,
    wallet,
    TXIDVersion.V2_PoseidonMerkle,
    DEFAULT_ENCRYPTION_KEY,
    () => process.stdout.write("."),
  );
  if (!depositTxs.length) throw new Error("no proved transactions for H2/H4 deposit");
  const normalized = normalizeTransactionForAdjudicator(depositTxs[0], chain.id);

  const depositTxn = await (adjudicator.connect(signer) as any).depositFromNote(channelId, expectedHeld, [normalized]);
  const depositReceipt = await depositTxn.wait();

  // ---- (infra) authorize a fresh delegate on the custodian via one FROST-signed `execute` ----
  // src/HubCustodian.sol: the FROST group authorizes cold operations (here, authorizeDelegate);
  // once authorized, the delegate's own plain ECDSA key signs channel states (H7), checked by
  // `isValidSignature`.
  const delegateWallet = ethers.Wallet.createRandom();
  const authorizeData = new ethers.Interface(["function authorizeDelegate(address delegate)"]).encodeFunctionData(
    "authorizeDelegate",
    [delegateWallet.address],
  );
  const opNonce: bigint = await custodian.nonce();
  const opHash: string = await custodian.operationHash(opNonce, custodianAddress, 0, authorizeData);
  const frostSig = JSON.parse(
    execFileSync(
      FROST_SIGNER,
      [
        "sign",
        "--shares",
        path.join(FROST_SHARES_DIR, "share-1"),
        path.join(FROST_SHARES_DIR, "share-2"),
        "--message",
        opHash,
        "--format",
        "json",
      ],
      { encoding: "utf-8" },
    ),
  ) as { commitmentX: string; commitmentY: string; z: string };
  const authorizeTxn = await (custodian.connect(signer) as any).execute(custodianAddress, 0, authorizeData, {
    commitmentX: frostSig.commitmentX,
    commitmentY: frostSig.commitmentY,
    z: frostSig.z,
  });
  await authorizeTxn.wait();

  // ---- H7: the wallet and the hub co-sign a channel state (user EOA + hub delegate) ----
  // The SHIELD payout note (npk2) is a fresh, real note of the SAME wallet (H1's wallet): its
  // commitment preimage and ciphertext come from the SDK's own shield-request serialization,
  // so the engine can later scan and spend it for H6.
  const { shieldRequest: payoutShieldRequest } = await createShieldRequest(
    { railgunAddress: walletInfo.railgunAddress, amount: DEPOSIT_AMOUNT, tokenAddress: usdcAddress },
    generateShieldPrivateKey(),
  );
  const npk2 = payoutShieldRequest.preimage.npk as string;
  const payoutMetadata = ethers.AbiCoder.defaultAbiCoder().encode(
    ["tuple(bytes32[3] encryptedBundle, bytes32 shieldKey)"],
    [payoutShieldRequest.ciphertext],
  );

  const outcome = [
    {
      asset: usdcAddress,
      assetMetadata: { assetType: 0, metadata: "0x" },
      allocations: [{ destination: npk2, amount: DEPOSIT_AMOUNT, allocationType: 3, metadata: payoutMetadata }],
    },
  ];
  const fixedPart = {
    participants,
    channelNonce,
    appDefinition: consensusApp,
    challengeDuration: CHALLENGE_DURATION,
  };
  const appData = "0x";
  const turnNum = 1;
  const isFinal = true;
  const stateHash = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "bytes", OUTCOME_TUPLE, "uint48", "bool"],
      [channelId, appData, outcome, turnNum, isFinal],
    ),
  );
  const userSig = await signState(userWallet, stateHash);
  const delegateSig = await signState(delegateWallet, stateHash);

  // ---- H5: the channel pays a SHIELD payout to the fresh note (conclude + transferAllAssets) ----
  const concludeTxn = await (adjudicator.connect(signer) as any).conclude(fixedPart, {
    variablePart: { outcome, appData, turnNum, isFinal },
    sigs: [userSig, delegateSig],
  });
  await concludeTxn.wait();
  const transferTxn = await (adjudicator.connect(signer) as any).transferAllAssets(channelId, outcome, stateHash);
  const transferReceipt = await transferTxn.wait();

  // ---- H6: the payout note (npk2) is unshielded to the second test EOA ----
  await waitForBalance(walletInfo.id, chain, wallet, usdcAddress, DEPOSIT_AMOUNT);
  const eoa2BalanceBefore = await usdc.balanceOf(eoa2);
  const unshieldBatch = createTransactionBatch(chain);
  addUnshieldOutput(unshieldBatch, eoa2, DEPOSIT_AMOUNT, usdcAddress);
  const unshieldTxs = await generateProvedTransactions(
    unshieldBatch,
    wallet,
    TXIDVersion.V2_PoseidonMerkle,
    DEFAULT_ENCRYPTION_KEY,
    () => process.stdout.write("."),
  );
  const unshieldCall = await generateTransactCall(TXIDVersion.V2_PoseidonMerkle, unshieldTxs, chain);
  const unshieldTxn = await signer.sendTransaction({ to: unshieldCall.to, data: unshieldCall.data });
  const unshieldReceipt = await unshieldTxn.wait();
  const eoa2BalanceAfter = await usdc.balanceOf(eoa2);
  const eoa2_usdc_delta = Number(eoa2BalanceAfter - eoa2BalanceBefore);

  // The payout note (npk2) was minted from walletInfo.railgunAddress's own masterPublicKey
  // (createShieldRequest above), the same wallet H1 shielded into -- a fresh note of the same
  // wallet, by construction.
  const payout_note_owned = npk2 !== ethers.ZeroHash && npk2 !== npk1;

  // ---- Write the disclosure package (records every transaction and event) ----
  fs.mkdirSync(path.dirname(PACKAGE_PATH), { recursive: true });
  const pkg = {
    statement: {
      verifier: "disclosure-acceptance",
      context: "armada-nitro selective-disclosure (arn-252)",
      chain: chain.id,
      pool: poolAddress,
      adjudicator: adjudicatorAddress,
      hops: ["H1", "H2", "H4", "H7", "H5", "H6"],
      eoa1,
      eoa2,
      masterPublicKey: walletInfo.railgunAddress,
      channelId,
    },
    transactions: [
      { hop: "H1", description: "EOA shields USDC into note npk1", transaction_hash: shieldReceipt!.hash },
      { hop: "H2/H4", description: "Note funds a hub channel via depositFromNote", transaction_hash: depositReceipt!.hash },
      { hop: "H7", description: "Wallet and hub delegate co-sign the final channel state", userSig, delegateSig, stateHash },
      { hop: "H5", description: "Channel pays SHIELD payout to a fresh note of the same wallet", transaction_hash: transferReceipt!.hash },
      { hop: "H6", description: "Note unshielded to the second EOA", transaction_hash: unshieldReceipt!.hash },
    ],
    events: [
      { hop: "H1", event: "Shield", npk: npk1 },
      { hop: "H2/H4", event: "Deposited", channelId, amount: DEPOSIT_AMOUNT.toString() },
      { hop: "H5", event: "Shield", npk: npk2 },
      { hop: "H6", event: "Unshield", to: eoa2, amount: DEPOSIT_AMOUNT.toString() },
    ],
  };
  fs.writeFileSync(PACKAGE_PATH, JSON.stringify(pkg, null, 2) + "\n");

  const result = {
    hops_ok: true,
    eoa2_usdc_delta,
    eoa_distinct,
    payout_note_owned,
    package_path: PACKAGE_PATH,
  };
  process.stdout.write(JSON.stringify(result) + "\n");
  await shutdownEngine();
}

main().then(
  () => {
    process.exit(0);
  },
  async (err) => {
    console.error("\ndisclosure.ts failed:", err);
    try {
      await shutdownEngine();
    } catch {
      /* ignore */
    }
    process.exit(1);
  },
);
