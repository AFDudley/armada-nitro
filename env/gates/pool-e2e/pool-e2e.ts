// ABOUTME: armada-env-verify gate, stage 2: our own shield/transfer/unshield e2e against this
// ABOUTME: environment's own PrivacyPool, real proofs, checked on chain independently of the SDK.

/**
 * `armada-env-verify` gate, stage 2 (E10).
 *
 * Armada's own scripts/capture/e2e-armada-circuits.ts (whose steps 1-3 this reuses the same
 * lib/sdk calls as, per the brief) goes on to a step 4 (yield) that needs Armada governance,
 * their yield adapter and their mock Aave -- none of which this environment deploys. This script
 * runs the same three real-proof steps against a test account and stops there:
 *
 *   1. shield 10 USDC (wallet A);
 *   2. privately transfer 3 USDC from wallet A to wallet B;
 *   3. unshield 1 USDC from wallet B to a second test account's public address.
 *
 * Each step's result is checked on chain, independently of the SDK:
 *   - the Shield / Transact / Unshield event, decoded from a minimal ABI defined here (not the
 *     SDK's own event handling);
 *   - the payer's (step 1) or recipient's (step 3) public USDC balance change, net of the pool's
 *     shield and unshield fees.
 *
 * Fee formulas, read from the deployed modules rather than assumed (contracts/privacy-pool/modules/):
 *   - shield (ShieldModule.sol's `_getFee`, the local-shield path -- no feeModule is deployed in
 *     this environment): an inclusive fee -- a shield of `amount` credits a note of
 *     `amount - amount*shieldFee()/10000` and takes `amount*shieldFee()/10000` to the treasury out
 *     of the same transfer (the payer's public balance still drops by the full gross `amount`).
 *     `shieldFee()` is 50 bps on this deployment (deploy_privacy_pool.ts step 10b).
 *   - unshield (TransactModule.sol's `_transferTokenOut`): pays the note's full value out with no
 *     fee logic at all ("Unshield is free per spec" -- see that function's comment).
 *     `unshieldFee()` (PrivacyPoolStorage.sol) is explicitly commented "DEPRECATED -- unshield is
 *     free per spec ... Always 0"; there is no setter for it anywhere in armada-poc, and
 *     deploy_privacy_pool.ts never calls one, so it reads 0 on every deployment of this pool
 *     version and TransactModule never consults it regardless of its value. This script still
 *     reads it live (rather than hardcoding 0) so the check is not assuming that -- see the
 *     brief's discrimination case (a) exercises a scratch copy that skips this read.
 *
 * Run via `npx hardhat run --network hub` from /src/armada-poc (copied to scripts/gates/pool-e2e.ts
 * there first, same as env/gates/nitro-e2e/prepare.ts -- see docker-compose-armada-env-verify.yml).
 */

import { ethers } from 'hardhat';
import * as fs from 'fs';

import { initializeEngine, shutdownEngine, clearDatabase, getEngine } from '../../lib/sdk/init';
import { createWallet, DEFAULT_ENCRYPTION_KEY } from '../../lib/sdk/wallet';
import { initializeProver } from '../../lib/sdk/prover';
import { createShieldRequest, generateShieldPrivateKey } from '../../lib/sdk/shield';
import { loadNetworkIntoEngine, scanWalletBalances } from '../../lib/sdk/network';
import { createPrivateTransfer, createUnshield, getSpendableBalance } from '../../lib/sdk/transfer';
import { getChainById, getRpcUrl } from '../../lib/sdk/chain-config';

import { TXIDVersion, POI, POINodeInterface, RailgunWallet } from '@railgun-community/engine';
import { ChainType, Chain } from '@railgun-community/shared-models';

// Same stub as scripts/capture/e2e-armada-circuits.ts / env/gates/nitro-e2e/prepare.ts -- POI is
// not part of this environment.
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
const SCAN_TIMEOUT_MS = 60_000;
const BASIS_POINTS = 10_000n;

const SHIELD_AMOUNT = ethers.parseUnits('10', 6);
const TRANSFER_AMOUNT = ethers.parseUnits('3', 6);
const UNSHIELD_AMOUNT = ethers.parseUnits('1', 6);


// Minimal ABI for the three module events, decoded independently of lib/sdk straight off the
// transaction receipts. Signatures are IShieldModule.Shield / ITransactModule.{Transact,Unshield}
// (armada-poc contracts/privacy-pool/interfaces/) -- emitted via delegatecall from PrivacyPool, so
// PrivacyPool's own default ABI (ethers.getContractAt('PrivacyPool', ...)) does not include them.
const EVENTS_ABI = [
  'event Shield(uint256 treeNumber, uint256 startPosition, tuple(bytes32 npk, tuple(uint8 tokenType, address tokenAddress, uint256 tokenSubID) token, uint120 value)[] commitments, tuple(bytes32[3] encryptedBundle, bytes32 shieldKey)[] shieldCiphertext, uint256[] fees)',
  'event Transact(uint256 treeNumber, uint256 startPosition, bytes32[] hash, tuple(bytes32[4] ciphertext, bytes32 blindedSenderViewingKey, bytes32 blindedReceiverViewingKey, bytes annotationData, bytes memo)[] ciphertext)',
  'event Unshield(address to, tuple(uint8 tokenType, address tokenAddress, uint256 tokenSubID) token, uint256 amount, uint256 fee)',
];
const eventsInterface = new ethers.Interface(EVENTS_ABI);

/** Decode every log in a receipt matching `eventName` from EVENTS_ABI. Independent of lib/sdk. */
function decodeEvents(receipt: any, eventName: string): ethers.LogDescription[] {
  const out: ethers.LogDescription[] = [];
  for (const log of receipt.logs) {
    try {
      const parsed = eventsInterface.parseLog({ topics: log.topics, data: log.data });
      if (parsed && parsed.name === eventName) out.push(parsed);
    } catch {
      /* not one of our three events -- e.g. the ERC20 Transfer/Approval logs in the same receipt */
    }
  }
  return out;
}

/** ShieldModule._getFee(amount, isInclusive=true, feeBps): base = amount - amount*feeBps/10000. */
function inclusiveFee(amount: bigint, feeBps: bigint): { base: bigint; fee: bigint } {
  if (feeBps === 0n) return { base: amount, fee: 0n };
  const base = amount - (amount * feeBps) / BASIS_POINTS;
  return { base, fee: amount - base };
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
  console.log('='.repeat(60));
  console.log('  armada-env-verify: pool e2e (shield / transfer / unshield)');
  console.log('='.repeat(60));

  const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf-8'));
  const poolAddress: string = manifest.armada.pool;
  const usdcAddress: string = manifest.armada.usdc;
  const deployBlock: number = manifest.armada.deployBlock ?? 0;
  const testAccounts: Array<{ address: string }> = manifest.testAccounts;
  if (!testAccounts || testAccounts.length < 2) {
    throw new Error('need at least two testAccounts in the manifest (funding.py funds anvil indices 1-4)');
  }

  const signers = await ethers.getSigners();
  const payer = signers.find((s) => s.address.toLowerCase() === testAccounts[0].address.toLowerCase());
  const recipient = signers.find((s) => s.address.toLowerCase() === testAccounts[1].address.toLowerCase());
  if (!payer || !recipient) {
    throw new Error('test accounts not found among hub network signers (mnemonic-derived)');
  }
  console.log(`payer=${payer.address} recipient=${recipient.address}`);

  const privacyPool = await ethers.getContractAt('PrivacyPool', poolAddress);
  // MockUSDCV2's ABI is an ERC20 superset (standard calls only) -- works against the real
  // FiatToken USDC too, same as scripts/capture/e2e-armada-circuits.ts relies on.
  const usdc = await ethers.getContractAt('MockUSDCV2', usdcAddress);

  const shieldFeeBps: bigint = await privacyPool.shieldFee();
  const unshieldFeeBps: bigint = await privacyPool.unshieldFee();
  console.log(`shieldFee()=${shieldFeeBps}bps unshieldFee()=${unshieldFeeBps}bps (read live from the pool)`);

  clearDatabase();
  await initializeEngine('poole2e');
  const chain: Chain = getChainById(31337) ?? { type: ChainType.EVM, id: 31337 };
  const rpcUrl = getRpcUrl(chain);
  await loadNetworkIntoEngine(chain, poolAddress, ethers.ZeroAddress, rpcUrl, deployBlock);
  await initializeProver();

  const walletA = await createWallet(DEFAULT_ENCRYPTION_KEY);
  const walletB = await createWallet(DEFAULT_ENCRYPTION_KEY);
  const engine = getEngine();
  const railgunA = engine.wallets[walletA.id] as unknown as RailgunWallet;
  const railgunB = engine.wallets[walletB.id] as unknown as RailgunWallet;
  console.log(`wallet A: ${walletA.railgunAddress}`);
  console.log(`wallet B: ${walletB.railgunAddress}`);

  // ═══════════════════════ STEP 1: SHIELD 10 USDC (wallet A) ═══════════════════════
  console.log('\n--- step 1: shield 10 USDC ---');
  const { base: expectedShieldNote, fee: expectedShieldFee } = inclusiveFee(SHIELD_AMOUNT, shieldFeeBps);

  const payerBalanceBefore: bigint = await usdc.balanceOf(payer.address);
  const shieldPrivateKey = generateShieldPrivateKey();
  const { shieldRequest } = await createShieldRequest(
    { railgunAddress: walletA.railgunAddress, amount: SHIELD_AMOUNT, tokenAddress: usdcAddress },
    shieldPrivateKey,
  );
  await (await usdc.connect(payer).approve(poolAddress, SHIELD_AMOUNT)).wait();
  const shieldReceipt = await (await privacyPool.connect(payer).shield([shieldRequest], ethers.ZeroAddress)).wait();
  console.log(`shield tx ${shieldReceipt!.hash}`);

  const shieldEvents = decodeEvents(shieldReceipt, 'Shield');
  if (shieldEvents.length !== 1) throw new Error(`expected 1 Shield event, saw ${shieldEvents.length}`);
  const shieldNoteValue = BigInt(shieldEvents[0].args.commitments[0].value);
  const shieldFeeValue = BigInt(shieldEvents[0].args.fees[0]);
  if (shieldNoteValue !== expectedShieldNote) {
    throw new Error(
      `Shield event note value ${shieldNoteValue} != expected ${expectedShieldNote} ` +
      `(10 USDC net of shieldFee()=${shieldFeeBps}bps)`,
    );
  }
  if (shieldFeeValue !== expectedShieldFee) {
    throw new Error(`Shield event fee ${shieldFeeValue} != expected ${expectedShieldFee}`);
  }
  console.log(
    `Shield event: note=${ethers.formatUnits(shieldNoteValue, 6)} USDC ` +
    `fee=${ethers.formatUnits(shieldFeeValue, 6)} USDC (matches shieldFee()=${shieldFeeBps}bps)`,
  );

  const payerBalanceAfter: bigint = await usdc.balanceOf(payer.address);
  const payerDelta = payerBalanceBefore - payerBalanceAfter;
  if (payerDelta !== SHIELD_AMOUNT) {
    throw new Error(
      `payer's public USDC balance dropped by ${payerDelta}, expected the full gross shield ` +
      `amount ${SHIELD_AMOUNT} (ShieldModule._transferTokenIn pulls base+fee == the gross amount)`,
    );
  }
  console.log(`payer's public USDC balance: -${ethers.formatUnits(payerDelta, 6)} USDC (gross)`);

  await waitForBalance(walletA.id, chain, railgunA, usdcAddress, expectedShieldNote, SCAN_TIMEOUT_MS);
  console.log(`wallet A spendable: ${ethers.formatUnits(expectedShieldNote, 6)} USDC`);

  // ═══════════════ STEP 2: PRIVATE TRANSFER 3 USDC, wallet A -> wallet B ═══════════════
  console.log('\n--- step 2: private transfer 3 USDC ---');
  const transferResult = await createPrivateTransfer({
    wallet: railgunA,
    chain,
    tokenAddress: usdcAddress,
    recipientAddress: walletB.railgunAddress,
    amount: TRANSFER_AMOUNT,
    encryptionKey: DEFAULT_ENCRYPTION_KEY,
    progressCallback: () => process.stdout.write('.'),
  });
  console.log('');
  const transferTx = await payer.sendTransaction({
    to: transferResult.contractTransaction.to,
    data: transferResult.contractTransaction.data,
  });
  const transferReceipt = await transferTx.wait();
  console.log(`transfer tx ${transferReceipt!.hash}`);

  const transactEvents = decodeEvents(transferReceipt, 'Transact');
  if (transactEvents.length !== 1) throw new Error(`expected 1 Transact event, saw ${transactEvents.length}`);
  const provedTransfer = transferResult.transactions[0];
  console.log(`Transact event: ${transactEvents[0].args.hash.length} new commitment(s)`);
  console.log(`circuit shape: ${provedTransfer.nullifiers.length}x${provedTransfer.commitments.length}`);

  await waitForBalance(walletB.id, chain, railgunB, usdcAddress, TRANSFER_AMOUNT, SCAN_TIMEOUT_MS);
  console.log(`wallet B spendable: ${ethers.formatUnits(TRANSFER_AMOUNT, 6)} USDC (transfers carry no fee)`);

  // ═══════════ STEP 3: UNSHIELD 1 USDC, wallet B -> recipient's public address ═══════════
  console.log('\n--- step 3: unshield 1 USDC ---');
  const { base: expectedUnshieldPayout } = inclusiveFee(UNSHIELD_AMOUNT, unshieldFeeBps);

  const recipientBalanceBefore: bigint = await usdc.balanceOf(recipient.address);
  const unshieldResult = await createUnshield({
    wallet: railgunB,
    chain,
    tokenAddress: usdcAddress,
    recipientAddress: recipient.address,
    amount: UNSHIELD_AMOUNT,
    encryptionKey: DEFAULT_ENCRYPTION_KEY,
    progressCallback: () => process.stdout.write('.'),
  });
  console.log('');
  const unshieldTx = await payer.sendTransaction({
    to: unshieldResult.contractTransaction.to,
    data: unshieldResult.contractTransaction.data,
  });
  const unshieldReceipt = await unshieldTx.wait();
  console.log(`unshield tx ${unshieldReceipt!.hash}`);

  const unshieldEvents = decodeEvents(unshieldReceipt, 'Unshield');
  if (unshieldEvents.length !== 1) throw new Error(`expected 1 Unshield event, saw ${unshieldEvents.length}`);
  const unshieldEvent = unshieldEvents[0];
  if (unshieldEvent.args.to.toLowerCase() !== recipient.address.toLowerCase()) {
    throw new Error(`Unshield event recipient ${unshieldEvent.args.to} != expected ${recipient.address}`);
  }
  const unshieldEventAmount = BigInt(unshieldEvent.args.amount);
  const unshieldEventFee = BigInt(unshieldEvent.args.fee);
  if (unshieldEventAmount !== expectedUnshieldPayout) {
    throw new Error(
      `Unshield event amount ${unshieldEventAmount} != expected ${expectedUnshieldPayout} ` +
      `(1 USDC net of unshieldFee()=${unshieldFeeBps}bps)`,
    );
  }
  console.log(
    `Unshield event: to=${unshieldEvent.args.to} amount=${ethers.formatUnits(unshieldEventAmount, 6)} USDC ` +
    `fee=${ethers.formatUnits(unshieldEventFee, 6)} USDC (matches unshieldFee()=${unshieldFeeBps}bps)`,
  );

  const provedUnshield = unshieldResult.transactions[0];
  console.log(`circuit shape: ${provedUnshield.nullifiers.length}x${provedUnshield.commitments.length}`);

  const recipientBalanceAfter: bigint = await usdc.balanceOf(recipient.address);
  const recipientDelta = recipientBalanceAfter - recipientBalanceBefore;
  if (recipientDelta !== expectedUnshieldPayout) {
    throw new Error(
      `recipient's public USDC balance rose by ${recipientDelta}, expected ${expectedUnshieldPayout} ` +
      `(1 USDC net of unshieldFee()=${unshieldFeeBps}bps)`,
    );
  }
  console.log(`recipient's public USDC balance: +${ethers.formatUnits(recipientDelta, 6)} USDC`);

  console.log(
    "\nverified: shield, private transfer and unshield each landed on chain with real proofs, " +
    "matching the pool's own fee getters",
  );
  await shutdownEngine();
}

main().then(() => process.exit(0)).catch(async (err) => {
  console.error('\npool-e2e.ts failed:', err);
  try { await shutdownEngine(); } catch { /* ignore */ }
  process.exit(1);
});
