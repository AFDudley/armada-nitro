// ABOUTME: Stage 1 of the armada-nitro-e2e gate. Shields USDC from a test account, then builds a
// ABOUTME: real-proof unshield to the adjudicator for two channels, writing deposits.json for stage 2.

/**
 * `armada-nitro-e2e` gate, stage 1.
 *
 * For CHANNEL_COUNT (2) channels: pick a random channelNonce, compute the real Nitro channelId
 * (NitroUtils.getChannelId's formula: keccak256(abi.encode(participants, channelNonce,
 * appDefinition, challengeDuration)) -- src/nitro/libraries/NitroUtils.sol), shield USDC from a
 * test account into the Armada pool, then build a Groth16-proved unshield of an ERC20 note to the
 * adjudicator:
 *   - UnshieldType.NORMAL (the engine's UnshieldNote is always a NORMAL unshield);
 *   - unshieldPreimage.npk = the adjudicator address (UnshieldData.toAddress becomes the note's
 *     npk verbatim -- @railgun-community/engine's UnshieldNote.npk getter returns toAddress);
 *   - boundParams.adaptContract / adaptParams set via TransactionBatch.setAdaptID({contract,
 *     parameters}) (lib/sdk/yield.ts's buildYieldAdaptTransaction is the existing precedent for
 *     this engine call in this codebase).
 *
 * adaptParams is read from the adjudicator by eth_call (adjudicator.depositBinding(channelId, 0)),
 * per the brief, rather than recomputed locally.
 *
 * Each channel gets its own fresh Railgun wallet and its own shield transaction (rather than one
 * wallet/shield shared by both channels). Neither of this run's unshield proofs is broadcast
 * before the other -- both are built locally and only submitted later, by stage 2's
 * depositFromNote calls -- so the engine's UTXO selection cannot yet see either as spent and
 * has no way to avoid picking the same note for both if they shared a wallet (confirmed by
 * running it that way first: the second channel's proof carried the same nullifier as the
 * first's, and its depositFromNote reverted "TransactModule: Note already spent" once the first
 * channel's deposit had already landed on chain). A dedicated wallet per channel makes that
 * collision structurally impossible.
 *
 * Writes deposits.json: per channel {channelId, channelNonce, amount, calldata, proofTimeMs}.
 * channelNonce is not in the brief's literal 3-field list but is required: stage 2
 * (FixturenetScenario.s.sol) must reconstruct the exact same FixedPart {participants,
 * channelNonce, appDefinition, challengeDuration} to derive the identical channelId (the hash
 * cannot be inverted the other way).
 *
 * Discrimination toggles (unset in the committed default path; used only for the brief's negative
 * cases, which run this script once with one of these set and a single channel):
 *   NITRO_E2E_BAD_ADAPT_PARAMS=1    bind adaptParams to depositBinding(channelId, 1) instead of 0
 *   NITRO_E2E_BAD_ADAPT_CONTRACT=1  set adaptContract to the test account instead of the adjudicator
 *
 * Run via `npx hardhat run --network hub` from /src/armada-poc (this file is copied to
 * scripts/gates/prepare.ts there first -- see docker-compose-armada-nitro-e2e.yml -- so its
 * relative lib/sdk imports resolve the same way scripts/capture/e2e-armada-circuits.ts's do).
 */

import { ethers } from 'hardhat';
import * as fs from 'fs';
import * as path from 'path';

import { initializeEngine, shutdownEngine, clearDatabase, getEngine } from '../../lib/sdk/init';
import { createWallet, DEFAULT_ENCRYPTION_KEY } from '../../lib/sdk/wallet';
import {
  initializeProver,
  createTransactionBatch,
  addUnshieldOutput,
  generateProvedTransactions,
} from '../../lib/sdk/prover';
import { createShieldRequest, generateShieldPrivateKey } from '../../lib/sdk/shield';
import { loadNetworkIntoEngine, scanWalletBalances } from '../../lib/sdk/network';
import { getSpendableBalance } from '../../lib/sdk/transfer';
import { getChainById, getRpcUrl } from '../../lib/sdk/chain-config';

import { TXIDVersion, POI, POINodeInterface, RailgunWallet } from '@railgun-community/engine';
import { ChainType, Chain } from '@railgun-community/shared-models';

// Same stub as scripts/capture/e2e-armada-circuits.ts -- POI is not part of this environment.
class StubPOINodeInterface extends POINodeInterface {
  isActive(): boolean { return false; }
  async isRequired(): Promise<boolean> { return false; }
  async getPOIsPerList(): Promise<Record<string, any>> { return {}; }
  async getPOIMerkleProofs(): Promise<any[]> { return []; }
  async validatePOIMerkleroots(): Promise<boolean> { return true; }
  async submitPOI(): Promise<void> { /* no-op */ }
  async submitLegacyTransactProofs(): Promise<void> { /* no-op */ }
}
POI.init([], new StubPOINodeInterface());

const MANIFEST_PATH = process.env.MANIFEST_PATH || '/env/manifest.json';
const OUTPUT_PATH = process.env.DEPOSITS_OUTPUT || '/env/nitro-e2e/deposits.json';
const CHALLENGE_DURATION = Number(process.env.CHALLENGE_DURATION || '30');
const BAD_ADAPT_PARAMS = process.env.NITRO_E2E_BAD_ADAPT_PARAMS === '1';
const BAD_ADAPT_CONTRACT = process.env.NITRO_E2E_BAD_ADAPT_CONTRACT === '1';
const CHANNEL_COUNT = BAD_ADAPT_PARAMS || BAD_ADAPT_CONTRACT ? 1 : 2;

const DEPOSIT_AMOUNT = ethers.parseUnits('100', 6); // 100 USDC per channel -- matches script/LocalScenario.s.sol's USER_FUNDS
const SHIELD_AMOUNT = ethers.parseUnits('150', 6); // gross per channel; nets ~149.25 USDC after the pool's 0.5% shield fee
const SCAN_TIMEOUT_MS = 60_000;

// Minimal ABI for the two adjudicator calls this script needs: reading the binding, and encoding
// depositFromNote's calldata. The Transaction tuple mirrors lib/sdk/yield.ts's ADAPTER_ABI (both
// ultimately forward the same struct to PrivacyPool.transact).
const ADJUDICATOR_ABI = [
  'function depositBinding(bytes32 channelId, uint256 expectedHeld) view returns (bytes32)',
  'function depositFromNote(bytes32 channelId, uint256 expectedHeld, tuple(tuple(tuple(uint256 x, uint256 y) a, tuple(uint256[2] x, uint256[2] y) b, tuple(uint256 x, uint256 y) c) proof, bytes32 merkleRoot, bytes32[] nullifiers, bytes32[] commitments, tuple(uint16 treeNumber, uint72 minGasPrice, uint8 unshield, uint64 chainID, address adaptContract, bytes32 adaptParams, tuple(bytes32[4] ciphertext, bytes32 blindedSenderViewingKey, bytes32 blindedReceiverViewingKey, bytes annotationData, bytes memo)[] commitmentCiphertext) boundParams, tuple(bytes32 npk, tuple(uint8 tokenType, address tokenAddress, uint256 tokenSubID) token, uint120 value) unshieldPreimage)[] transactions) returns ()',
];

/** Normalize the proved TransactionStructV2 into the tuple the adjudicator ABI expects. Ported
 * from lib/sdk/yield.ts's normalizeTransactionForAdapter (that file's version is private to it). */
function normalizeTransactionForAdjudicator(tx: unknown, chainId: number): unknown {
  const toBigInt = (v: unknown): bigint => {
    if (v == null) return 0n;
    if (typeof v === 'bigint') return v;
    if (typeof v === 'number' || typeof v === 'string') return BigInt(v);
    return 0n;
  };
  const toHex = (v: unknown): string => {
    if (v == null) return ethers.ZeroHash;
    if (typeof v === 'string' && v.startsWith('0x')) return v;
    try { return ethers.hexlify(v as ethers.BytesLike); } catch { return ethers.ZeroHash; }
  };
  const t = tx as Record<string, unknown>;
  const bp = t.boundParams as Record<string, unknown> | undefined;
  const rawCiphertext = (bp?.commitmentCiphertext ?? []) as Array<Record<string, unknown> | null | undefined>;
  const defaultCiphertext: [string, string, string, string] = [
    ethers.ZeroHash, ethers.ZeroHash, ethers.ZeroHash, ethers.ZeroHash,
  ];
  const commitmentCiphertext = rawCiphertext
    .filter((c): c is Record<string, unknown> => c != null)
    .map((c) => {
      const ct = c.ciphertext as string[] | undefined;
      const arr = Array.isArray(ct) && ct.length >= 4
        ? [ct[0], ct[1], ct[2], ct[3]] as [string, string, string, string]
        : defaultCiphertext;
      return {
        ciphertext: arr,
        blindedSenderViewingKey: (c.blindedSenderViewingKey ?? ethers.ZeroHash) as string,
        blindedReceiverViewingKey: (c.blindedReceiverViewingKey ?? ethers.ZeroHash) as string,
        annotationData: (c.annotationData ?? '0x') as string,
        memo: (c.memo ?? '0x') as string,
      };
    });

  const up = t.unshieldPreimage as Record<string, unknown> | undefined;
  const token = (up?.token ?? {}) as Record<string, unknown>;
  const unshieldPreimage = {
    npk: toHex(up?.npk) || ethers.ZeroHash,
    token: {
      tokenType: Number(token.tokenType ?? 0),
      tokenAddress: (token.tokenAddress != null ? String(token.tokenAddress) : ethers.ZeroAddress) as string,
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
    nullifiers: ((t.nullifiers ?? []) as unknown[]).map((n) => toHex(n) || ethers.ZeroHash) as string[],
    commitments: ((t.commitments ?? []) as unknown[]).map((c) => toHex(c) || ethers.ZeroHash) as string[],
    boundParams: {
      treeNumber: Number(bp?.treeNumber ?? 0),
      minGasPrice: toBigInt(bp?.minGasPrice),
      unshield: Number(bp?.unshield ?? 1),
      chainID: toBigInt(bp?.chainID) || BigInt(chainId),
      adaptContract: (bp?.adaptContract != null ? String(bp.adaptContract) : ethers.ZeroAddress) as string,
      adaptParams: toHex(bp?.adaptParams) || ethers.ZeroHash,
      commitmentCiphertext,
    },
    unshieldPreimage,
  };
}

async function waitForBalance(
  walletId: string, chain: Chain, wallet: any, tokenAddress: string, minAmount: bigint, timeoutMs: number,
): Promise<bigint> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    await scanWalletBalances(walletId, chain);
    const bal = await getSpendableBalance(wallet, chain, tokenAddress);
    if (bal >= minAmount) return bal;
    await new Promise((r) => setTimeout(r, 3000));
  }
  throw new Error(`spendable balance didn't reach ${minAmount} within ${timeoutMs / 1000}s`);
}

async function main() {
  const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf-8'));
  const poolAddress: string = manifest.armada.pool;
  const usdcAddress: string = manifest.armada.usdc;
  const deployBlock: number = manifest.armada.deployBlock ?? 0;
  const adjudicatorAddress: string = manifest.armadaNitro.adjudicator;
  const consensusApp: string = manifest.armadaNitro.consensusApp;
  const custodian: string = manifest.armadaNitro.hubCustodian;
  const testAccountAddress: string = manifest.testAccounts[0].address;

  console.log(`pool=${poolAddress} usdc=${usdcAddress} adjudicator=${adjudicatorAddress}`);
  console.log(`consensusApp=${consensusApp} custodian=${custodian} testAccount=${testAccountAddress}`);
  console.log(`channels=${CHANNEL_COUNT} challengeDuration=${CHALLENGE_DURATION}`);
  if (BAD_ADAPT_PARAMS) console.log('DISCRIMINATION MODE: binding adaptParams to depositBinding(channelId, 1)');
  if (BAD_ADAPT_CONTRACT) console.log('DISCRIMINATION MODE: setting adaptContract to the test account');

  const signers = await ethers.getSigners();
  const user = signers.find((s) => s.address.toLowerCase() === testAccountAddress.toLowerCase());
  if (!user) {
    throw new Error(
      `test account ${testAccountAddress} not found among hub network signers (mnemonic-derived); ` +
      `expected it at signers[1] (anvil mnemonic index 1)`
    );
  }

  const privacyPool = await ethers.getContractAt('PrivacyPool', poolAddress);
  // MockUSDCV2's ABI is an ERC20 superset (standard calls only) -- works against the real
  // FiatToken USDC too, same as scripts/capture/e2e-armada-circuits.ts relies on.
  const usdc = await ethers.getContractAt('MockUSDCV2', usdcAddress);
  const adjudicatorRead = new ethers.Contract(adjudicatorAddress, ADJUDICATOR_ABI, ethers.provider);
  const depositIface = new ethers.Interface(ADJUDICATOR_ABI);

  clearDatabase();
  await initializeEngine('nitroe2e');
  const chain: Chain = getChainById(31337) ?? { type: ChainType.EVM, id: 31337 };
  const rpcUrl = getRpcUrl(chain);
  await loadNetworkIntoEngine(chain, poolAddress, ethers.ZeroAddress, rpcUrl, deployBlock);
  await initializeProver();

  // ---- Per channel: own wallet, own shield, then a real-proof unshield bound to the adjudicator ----
  const deposits: Array<{
    channelId: string; channelNonce: string; amount: string; calldata: string; proofTimeMs: number;
  }> = [];

  for (let i = 0; i < CHANNEL_COUNT; i++) {
    const walletInfo = await createWallet(DEFAULT_ENCRYPTION_KEY);
    const engine = getEngine();
    const wallet = engine.wallets[walletInfo.id] as unknown as RailgunWallet;
    console.log(`\nchannel ${i}: shielding wallet ${walletInfo.railgunAddress}`);

    const shieldPrivateKey = generateShieldPrivateKey();
    const { shieldRequest } = await createShieldRequest(
      { railgunAddress: walletInfo.railgunAddress, amount: SHIELD_AMOUNT, tokenAddress: usdcAddress },
      shieldPrivateKey,
    );
    await (await usdc.connect(user).approve(poolAddress, SHIELD_AMOUNT)).wait();
    const shieldTx = await privacyPool.connect(user).shield([shieldRequest], ethers.ZeroAddress);
    const shieldReceipt = await shieldTx.wait();
    console.log(`channel ${i}: shield tx ${shieldReceipt!.hash}`);

    const spendable = await waitForBalance(walletInfo.id, chain, wallet, usdcAddress, DEPOSIT_AMOUNT, SCAN_TIMEOUT_MS);
    console.log(`channel ${i}: spendable after shield ${ethers.formatUnits(spendable, 6)} USDC`);

    const channelNonce = ethers.toBigInt(ethers.hexlify(ethers.randomBytes(8))); // uint64
    const participants = [user.address, custodian];
    const channelId = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['address[]', 'uint64', 'address', 'uint48'],
        [participants, channelNonce, consensusApp, CHALLENGE_DURATION],
      ),
    );

    const expectedHeld = 0n;
    const boundExpectedHeld = BAD_ADAPT_PARAMS ? 1n : expectedHeld;
    const adaptParams: string = await adjudicatorRead.depositBinding(channelId, boundExpectedHeld);
    const adaptContract = BAD_ADAPT_CONTRACT ? user.address : adjudicatorAddress;

    const batch = createTransactionBatch(chain);
    addUnshieldOutput(batch, adjudicatorAddress, DEPOSIT_AMOUNT, usdcAddress);
    batch.setAdaptID({ contract: adaptContract, parameters: adaptParams });

    const proofStart = Date.now();
    const transactions = await generateProvedTransactions(
      batch, wallet, TXIDVersion.V2_PoseidonMerkle, DEFAULT_ENCRYPTION_KEY,
      (p: any) => process.stdout.write(`.`),
    );
    const proofTimeMs = Date.now() - proofStart;
    console.log(`\nchannel ${i}: channelId=${channelId} proof time=${proofTimeMs}ms`);

    if (!transactions.length) throw new Error(`channel ${i}: SDK returned no proved transactions`);
    const normalized = normalizeTransactionForAdjudicator(transactions[0], chain.id);
    const calldata = depositIface.encodeFunctionData('depositFromNote', [channelId, expectedHeld, [normalized]]);

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
        custodian,
        user: user.address,
        challengeDuration: CHALLENGE_DURATION,
        deposits,
      },
      null,
      2,
    ) + '\n',
  );
  console.log(`\nwrote ${OUTPUT_PATH}`);
  for (const d of deposits) {
    console.log(`  channel ${d.channelId}: amount=${ethers.formatUnits(d.amount, 6)} USDC proofTimeMs=${d.proofTimeMs}`);
  }

  await shutdownEngine();
}

main().then(() => {
  process.exit(0);
}).catch(async (err) => {
  console.error('\nprepare.ts failed:', err);
  try { await shutdownEngine(); } catch { /* ignore */ }
  process.exit(1);
});
