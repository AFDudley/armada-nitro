// ABOUTME: One scenario per external function of PoolSol (env/armada-sol/PoolSol.sol) on the
// ABOUTME: fixturenet, each checked on chain, with one verdict line per function.

/**
 * PoolSol scenarios (armada-laconic `labbook/2026-11-11-concrete-specification-design.md` §7,
 * item 5). The manifest's `armadaSol` entry (env/reconciler/modules/armada_sol.py) names the pool.
 * The scenarios run in this order, because `shield` needs a fee ratio:
 *
 *   1. setFeeRatio(1, 200) from the fee admin: the `FeeRatioSet` event, and storage slot 23
 *      (`feeRatio`, solc's layout) holds the two halves.
 *   2. shield 10 USDC: the payer's balance drops by 10 USDC, the pool's rises by 10 USDC, and the
 *      `Shielded` commitment equals Poseidon(npk, token, 10 USDC less the fee), computed here with
 *      circomlibjs, not with the pool's Poseidon contract.
 *   3. transact: a real Groth16 proof of a private transfer, made by Armada's SDK against Armada's
 *      own pool on the same chain. The SDK encodes Railgun's `transact` (selector d8ae136a); this
 *      script adds `ownerField = 0` and `publicOutputs = []` to make PoolSol's `transact`
 *      (407ae1b2). Both pools hash only the seven core bound parameters into the proof, so the
 *      proof stays valid. The proof's Merkle root is a root of Armada's tree. PoolSol's
 *      `insertLeaf` is not the frontier walk yet, so the expected result is a revert with
 *      `unknownRoot`, and the verdict is FAIL until the tree is real.
 *   4. transactOwned: the same transaction under selector 4b5d810b. Its `ownerField` is zero, not
 *      the caller, so the expected revert is `ownerMismatch`. The circuit release has no owned
 *      circuit, so no owned proof exists; the verdict is FAIL.
 *
 * Each verdict line is `VERDICT <function> PASS|FAIL <detail>`. The script exits non-zero when any
 * verdict is FAIL.
 *
 * Run via `npx hardhat run --network hub` from /src/armada-poc, copied to scripts/gates/ there
 * first (stack/compose-jobs/docker-compose-armada-sol-scenario.yml).
 */

import { ethers } from "hardhat";
import * as fs from "fs";
import { buildPoseidon } from "circomlibjs";

import {
  initializeEngine,
  clearDatabase,
  getEngine,
  shutdownEngine,
} from "../../lib/sdk/init";
import { createWallet, DEFAULT_ENCRYPTION_KEY } from "../../lib/sdk/wallet";
import { initializeProver } from "../../lib/sdk/prover";
import {
  createShieldRequest,
  generateShieldPrivateKey,
} from "../../lib/sdk/shield";
import {
  loadNetworkIntoEngine,
  scanWalletBalances,
} from "../../lib/sdk/network";
import {
  createPrivateTransfer,
  getSpendableBalance,
} from "../../lib/sdk/transfer";
import { getChainById, getRpcUrl } from "../../lib/sdk/chain-config";

import {
  POI,
  POINodeInterface,
  RailgunWallet,
} from "@railgun-community/engine";
import { ChainType, Chain } from "@railgun-community/shared-models";

// Same stub as env/gates/pool-e2e/pool-e2e.ts -- POI is not part of this environment.
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
const SOURCE_PATH =
  process.env.POOLSOL_SOURCE || "/src/armada-nitro/env/armada-sol/PoolSol.sol";
const SCAN_TIMEOUT_MS = 60_000;
const SHIELD_AMOUNT = ethers.parseUnits("10", 6);
const TRANSFER_AMOUNT = ethers.parseUnits("3", 6);
const FEE_NUM = 1n;
const FEE_DEN = 200n;
const FEE_RATIO_SLOT = 23n;

// PoolSol's Transaction (out/PoolSol.sol); Railgun's is the same without the last two fields of
// BoundParams (ownerField, publicOutputs).
const PREIMAGE = "(bytes32,(uint8,address,uint256),uint120)";
const CIPHERTEXT = "(bytes32[4],bytes32,bytes32,bytes,bytes)";
const PROOF = "((uint256,uint256),(uint256[2],uint256[2]),(uint256,uint256))";
const POOL_TXN = `(${PROOF},bytes32,bytes32[],bytes32[],(uint16,uint72,uint8,uint64,address,bytes32,${CIPHERTEXT}[],bytes32,${PREIMAGE}[]),${PREIMAGE})`;
const RAILGUN_TXN = `(${PROOF},bytes32,bytes32[],bytes32[],(uint16,uint72,uint8,uint64,address,bytes32,${CIPHERTEXT}[]),${PREIMAGE})`;

type Verdict = { fn: string; pass: boolean; detail: string };

function poolInterface(source: string): ethers.Interface {
  const errors = [...source.matchAll(/^\s*error (\w+)\(\);/gm)].map(
    (m) => `error ${m[1]}()`,
  );
  return new ethers.Interface([
    "function shield(address token, uint256 amount, bytes32 npk)",
    "function setFeeRatio(uint128 num, uint128 den)",
    `function transact(${POOL_TXN}[] batch)`,
    `function transactOwned(${POOL_TXN}[] batch)`,
    "event Shielded(bytes32 commitment, uint256 amount)",
    "event FeeRatioSet(uint128 num, uint128 den)",
    ...errors,
  ]);
}

/** The custom error a call reverts with, or "none" when it does not revert. */
async function revertName(
  iface: ethers.Interface,
  from: ethers.Signer,
  to: string,
  data: string,
): Promise<string> {
  try {
    await from.call({ to, data });
    return "none";
  } catch (e: unknown) {
    const err = e as { data?: string; info?: { error?: { data?: string } } };
    const revertData = err.data ?? err.info?.error?.data;
    if (!revertData) throw e;
    const parsed = iface.parseError(revertData);
    return parsed ? parsed.name : `unknown(${revertData})`;
  }
}

async function waitForBalance(
  walletId: string,
  chain: Chain,
  wallet: RailgunWallet,
  tokenAddress: string,
  minAmount: bigint,
): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < SCAN_TIMEOUT_MS) {
    await scanWalletBalances(walletId, chain);
    if ((await getSpendableBalance(wallet, chain, tokenAddress)) >= minAmount)
      return;
    await new Promise((r) => setTimeout(r, 3000));
  }
  throw new Error(
    `spendable balance didn't reach ${minAmount} within ${SCAN_TIMEOUT_MS / 1000}s`,
  );
}

async function main() {
  const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, "utf-8"));
  const poolSol: string = manifest.armadaSol.pool;
  const armadaPool: string = manifest.armada.pool;
  const usdcAddress: string = manifest.armada.usdc;
  const iface = poolInterface(fs.readFileSync(SOURCE_PATH, "utf-8"));
  for (const [fn, selector] of [
    ["transact", "0x407ae1b2"],
    ["transactOwned", "0x4b5d810b"],
  ]) {
    if (iface.getFunction(fn)!.selector !== selector)
      throw new Error(
        `${fn} selector ${iface.getFunction(fn)!.selector}, expected ${selector}`,
      );
  }

  const signers = await ethers.getSigners();
  const byAddress = (a: string) => {
    const s = signers.find((x) => x.address.toLowerCase() === a.toLowerCase());
    if (!s) throw new Error(`${a} is not among the hub network's signers`);
    return s;
  };
  const feeAdmin = byAddress(manifest.armadaSol.feeAdmin);
  const payer = byAddress(manifest.testAccounts[0].address);
  const pool = new ethers.Contract(poolSol, iface, ethers.provider);
  const usdc = await ethers.getContractAt("MockUSDCV2", usdcAddress);
  const verdicts: Verdict[] = [];

  // 1. setFeeRatio
  {
    const receipt = await (
      await pool.connect(feeAdmin).getFunction("setFeeRatio")(FEE_NUM, FEE_DEN)
    ).wait();
    const events = receipt!.logs
      .map((l: ethers.Log) => iface.parseLog(l))
      .filter((e) => e?.name === "FeeRatioSet");
    const slot = BigInt(
      await ethers.provider.getStorage(poolSol, FEE_RATIO_SLOT),
    );
    const stored = { num: slot & ((1n << 128n) - 1n), den: slot >> 128n };
    const pass =
      events.length === 1 &&
      events[0]!.args.num === FEE_NUM &&
      events[0]!.args.den === FEE_DEN &&
      stored.num === FEE_NUM &&
      stored.den === FEE_DEN;
    verdicts.push({
      fn: "setFeeRatio",
      pass,
      detail: `tx ${receipt!.hash}; FeeRatioSet events ${events.length}; slot 23 = ${stored.num}/${stored.den}`,
    });
  }

  // 2. shield
  {
    const poseidon = await buildPoseidon();
    const npk = BigInt(ethers.hexlify(ethers.randomBytes(31)));
    const fee = (SHIELD_AMOUNT * FEE_NUM) / FEE_DEN;
    const expected = BigInt(
      poseidon.F.toString(
        poseidon([npk, BigInt(usdcAddress), SHIELD_AMOUNT - fee]),
      ),
    );
    const payerBefore: bigint = await usdc.balanceOf(payer.address);
    const poolBefore: bigint = await usdc.balanceOf(poolSol);
    await (await usdc.connect(payer).approve(poolSol, SHIELD_AMOUNT)).wait();
    const receipt = await (
      await pool.connect(payer).getFunction("shield")(
        usdcAddress,
        SHIELD_AMOUNT,
        ethers.toBeHex(npk, 32),
      )
    ).wait();
    const events = receipt!.logs
      .filter(
        (l: ethers.Log) => l.address.toLowerCase() === poolSol.toLowerCase(),
      )
      .map((l: ethers.Log) => iface.parseLog(l))
      .filter((e) => e?.name === "Shielded");
    const payerDelta = payerBefore - (await usdc.balanceOf(payer.address));
    const poolDelta = (await usdc.balanceOf(poolSol)) - poolBefore;
    const commitment =
      events.length === 1 ? BigInt(events[0]!.args.commitment) : -1n;
    const pass =
      events.length === 1 &&
      commitment === expected &&
      events[0]!.args.amount === SHIELD_AMOUNT &&
      payerDelta === SHIELD_AMOUNT &&
      poolDelta === SHIELD_AMOUNT;
    verdicts.push({
      fn: "shield",
      pass,
      detail:
        `tx ${receipt!.hash}; commitment ${ethers.toBeHex(commitment < 0n ? 0n : commitment, 32)} ` +
        `(expected ${ethers.toBeHex(expected, 32)}); payer -${payerDelta}; pool +${poolDelta}`,
    });
  }

  // 3 and 4. a real proof from Armada's SDK against Armada's own pool
  clearDatabase();
  await initializeEngine("armadasol");
  const chain: Chain = getChainById(31337) ?? {
    type: ChainType.EVM,
    id: 31337,
  };
  await loadNetworkIntoEngine(
    chain,
    armadaPool,
    ethers.ZeroAddress,
    getRpcUrl(chain),
    manifest.armada.deployBlock ?? 0,
  );
  await initializeProver();
  const walletA = await createWallet(DEFAULT_ENCRYPTION_KEY);
  const walletB = await createWallet(DEFAULT_ENCRYPTION_KEY);
  const railgunA = getEngine().wallets[walletA.id] as unknown as RailgunWallet;
  const { shieldRequest } = await createShieldRequest(
    {
      railgunAddress: walletA.railgunAddress,
      amount: SHIELD_AMOUNT,
      tokenAddress: usdcAddress,
    },
    generateShieldPrivateKey(),
  );
  const armada = await ethers.getContractAt("PrivacyPool", armadaPool);
  await (await usdc.connect(payer).approve(armadaPool, SHIELD_AMOUNT)).wait();
  await (
    await armada.connect(payer).shield([shieldRequest], ethers.ZeroAddress)
  ).wait();
  await waitForBalance(
    walletA.id,
    chain,
    railgunA,
    usdcAddress,
    TRANSFER_AMOUNT,
  );
  const transfer = await createPrivateTransfer({
    wallet: railgunA,
    chain,
    tokenAddress: usdcAddress,
    recipientAddress: walletB.railgunAddress,
    amount: TRANSFER_AMOUNT,
    encryptionKey: DEFAULT_ENCRYPTION_KEY,
  });
  const railgunIface = new ethers.Interface([
    `function transact(${RAILGUN_TXN}[] batch)`,
  ]);
  const engineData: string = transfer.contractTransaction.data;
  if (
    engineData.slice(0, 10) !== railgunIface.getFunction("transact")!.selector
  )
    throw new Error(
      `the SDK's calldata selector is ${engineData.slice(0, 10)}, not Railgun's transact`,
    );
  const [railgunBatch] = railgunIface.decodeFunctionData(
    "transact",
    engineData,
  );
  const batch = railgunBatch.map((t: ethers.Result) => {
    const [proof, merkleRoot, nullifiers, commitments, bp, unshieldPreimage] =
      t.toArray(true);
    return [
      proof,
      merkleRoot,
      nullifiers,
      commitments,
      [...bp, ethers.ZeroHash, []],
      unshieldPreimage,
    ];
  });
  const shape = `${batch[0][2].length}x${batch[0][3].length}`;
  const root = batch[0][1];

  for (const [fn, expected] of [
    ["transact", "unknownRoot"],
    ["transactOwned", "ownerMismatch"],
  ]) {
    const got = await revertName(
      iface,
      payer,
      poolSol,
      iface.encodeFunctionData(fn, [batch]),
    );
    verdicts.push({
      fn,
      pass: got === "none",
      detail: `real ${shape} proof, root ${root}; reverted ${got} (expected ${expected} while the shallow tree and the missing owned circuit stand)`,
    });
  }

  for (const v of verdicts)
    console.log(`VERDICT ${v.fn} ${v.pass ? "PASS" : "FAIL"} ${v.detail}`);
  await shutdownEngine();
  return verdicts.every((v) => v.pass) ? 0 : 1;
}

// The engine keeps handles open after shutdown, so the script exits explicitly (as pool-e2e.ts does).
main()
  .then((code) => process.exit(code))
  .catch((e) => {
    console.error(e);
    process.exit(2);
  });
