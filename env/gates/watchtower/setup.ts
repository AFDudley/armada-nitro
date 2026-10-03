/**
 * E15a scenario setup: funds the demonstration channel and triggers the counterparty's challenge.
 *   - stale:   fund the channel, then the counterparty challenges with the STALE state (turn N=10).
 *   - current:  fund the channel, then the counterparty challenges with the LATEST state (turn N+1=11),
 *                which is the same state the watcher holds -> the watcher must NOT respond.
 *
 * The watcher (watch.ts) is running in parallel, subscribed to the ChallengeRegistered event.
 *
 * Environment variables (set by scenario.sh): the same WT_* vars as watch.ts, plus:
 *   ST_MODE              "stale" or "current"
 *   ST_FUND_AMOUNT       USDC amount to fund the channel (default 100)
 */

import { ethers } from "ethers";
import * as fs from "fs";

function env(name: string, dflt?: string): string {
  const v = process.env[name];
  if (v === undefined) {
    if (dflt !== undefined) return dflt;
    throw new Error(`missing env ${name}`);
  }
  return v;
}
function envInt(name: string, dflt: number): number {
  const v = process.env[name];
  return v !== undefined ? Number(v) : dflt;
}

interface HeldState { turnNum: number; isFinal: boolean; userAmount: number; hubAmount: number; }
interface Ctx {
  rpc: string; manifest: string; keysDir: string;
  user: string; custodian: string; app: string;
  nonce: number; duration: number; delegateKey: string;
  usdc: string; adjudicator: string;
}

function loadCtx(): Ctx {
  const ctx: Ctx = {
    rpc: env("WT_RPC", "http://127.0.1:8545"),
    manifest: env("WT_MANIFEST"),
    keysDir: env("WT_KEYS"),
    user: env("WT_USER"),
    custodian: env("WT_CUSTODIAN"),
    app: env("WT_APP"),
    nonce: envInt("WT_NONCE", 0),
    duration: envInt("WT_CHALLENGE_DURATION", 30),
    delegateKey: env("WT_DELEGATE_KEY"),
    usdc: "", adjudicator: "",
  };
  const manifest = JSON.parse(fs.readFileSync(ctx.manifest, "utf8"));
  ctx.adjudicator = manifest.armadaNitro.adjudicator;
  ctx.usdc = manifest.armada.usdc;
  return ctx;
}

const FP = "(address[] participants, uint64 channelNonce, address appDefinition, uint48 challengeDuration)";
const ALLOC = "(bytes32 destination, uint256 amount, uint8 allocationType, bytes metadata)";
const OUTCOME = "(address asset, (uint8 assetType, bytes metadata) assetMetadata, " + ALLOC + ")";
const VARIOUS = "(uint48 turnNum, bytes appData, " + OUTCOME + " outcome, bool isFinal)";
const SIG = "(uint8 v, bytes32 r, bytes32 s)";
const SIGNED = "(" + VARIOUS + " variablePart, (" + SIG + ") sigs)";
const ABI = [
  "function deposit(address asset, bytes32 channelId, uint256 expectedHeld, uint256 amount)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function challenge(" + FP + " fixedPart, (" + VARIOUS + ")[] proof, (" + VARIOUS + " variablePart, (" + SIG + ") sigs) candidate, (" + SIG + ") challengerSig)",
];

function encodeKeccak(types: string[], values: any[]): string {
  const coder = new ethers.AbiCoder();
  const bytes = coder.encode(types, values)
  return ethers.keccak256(bytes);
}

function channelId(ctx: Ctx): string {
  return encodeKeccak(
    ["address[]", "uint64", "address", "uint48"],
    [[ctx.user, ctx.custodian], ctx.nonce, ctx.app, ctx.duration]
  );
}

function buildOutcome(ctx: Ctx, state: { turnNum: number; isFinal: boolean; userAmount: number; hubAmount: number }): any {
  const alloc = [
    { destination: "0x0000000000000000000000000000000000000000000000000000000002222
    , amount: state.userAmount, allocationType: 3, metadata: "0x" },
    { destination: ethers.zeroPadValue(ctx.custodian, 32), amount: state.hubAmount, allocationType: 0, metadata: "0x" },
  ];
  return { asset: ctx.usdc, assetMetadata: { assetType: 0, metadata: "0x" }, allocations: alloc };
}

function signState(ctx: Ctx, state: { turnNum: number; isFinal: boolean; userAmount: number; hubAmount: number }): { variablePart: any; sigs: any[] } {
  const cid = channelId(ctx);
  const variablePart = {
    turnNum: state.turnNum,
    appData: "0x",
    outcome: [buildOutcome(ctx, state)],
    isFinal: state.isFinal,
  };
  const stateHash = encodeKeccak(
    ["bytes32", "bytes", "(address,(uint8,bytes),((bytes32,uint256,uint8,bytes)[])", "uint48", "bool"],
    [cid, variablePart.appData, variablePart.outcome, variablePart.turnNum, variablePart.isFinal]
  );
  const userKey = fs.readFileSync(`${ctx.keysDir}/${env("WT_KEY_FILE")}`, "utf8").trim();
  const userWallet = new ethers.Wallet(userKey);
  const delegateWallet = new ethers.Wallet(ctx.delegateKey);
  const userSig = userWallet.signMessage(stateHash);
  const delegateSig = delegateWallet.signMessage(stateHash);
  return { variablePart, sigs: [decodeSig(userSig), decodeSig(delegateSig)] };
}

function decodeSig(sig: string): { v: number; r: string; s: string } {
  const raw = ethers.utils.toArray(sig);
  const v = raw[64];
  const r = "0x" + Buffer.from(raw, 0, 32).toString("hex");
  const s = "0x" + Buffer.from(raw, 32, 64).toString("hex");
  return { v, r, s };
}

async function main() {
  const ctx = loadCtx();
  const mode = env("ST_MODE");
  const fundAmount = envInt("ST_FUND_AMOUNT", 100);

  const cid = channelId(ctx);
  const provider = new ethers.JsonRpcProvider(ctx.rpc);
  const adjudicator = new ethers.Contract(ctx.adjudicator, ABI, provider);
  const usdc = new ethers.Contract(ctx.usdc, ["function approve(address,uint256) returns (bool)"], provider);
  const userKey = fs.readFileSync(`${ctx.keysDir}/${env("WT_KEY_FILE")}`, "utf8").trim();
  const userWallet = new ethers.Wallet(userKey, provider);

  // 1. Fund the channel: approve + deposit
  const approve = await usdc.approve(ctx.adjudicator, fundAmount, {
    provider: userWallet,
  });
  await approve.wait();
  const deposit = await adjudicator.deposit(ctx.usdc, cid, 0, fundAmount, {
    provider: userWallet,
  });
  await deposit.wait();
  console.log(`funded channel ${ethers.utils.toHex(cid)}: USDC ${fundAmount}`);

  // 2. Determine the challenge's candidate state based on mode
  let state;
  if (mode === "stale") {
    // counterparty challenges with the stale state (turn 10)
    state = { turnNum: 10, isFinal: false, userAmount: 50, hubAmount: 50 };
  } else {
    // counterparty challenges with the latest state (turn 11), same as the watcher's held state
    state = { turnNum: 11, isFinal: false, userAmount: 100, hubAmount: 50 };
  }

  // 3. Trigger the counterparty's challenge
  const signed = signState(ctx, state);
  const cid2 = cid;
  const stateHash = encodeKeccak(
    ["bytes32", "bytes", "(address,(uint8,bytes),((bytes32,uint256,uint8,bytes)[])", "uint48", "bool"],
    [cid2, signed.variablePart.appData, signed.variablePart.outcome, signed.variablePart.turnNum, signed.variablePart.isFinal]
  );
  const challengerDigest = ethers.keccak256(
    new ethers.AbiCoder().encode(["bytes32", "string"], [stateHash, "forceMove"])
  );
  const challengerSig = decodeSig(userWallet.signMessage(challengerDigest));
  const fp = {
    participants: [ctx.user, ctx.custodian],
    channelNonce: ctx.nonce,
    appDefinition: ctx.app,
    challengeDuration: ctx.duration,
  };
  const challenge = await adjudicator.challenge(
    fp,
    [],
    { variablePart: signed.variablePart, sigs: signed.sigs },
    { v: 0, r: "", s: "" }, // placeholder
  );
  console.log("challenge tx:", challenge.hash);
  await challenge.wait();
  console.log(`challenge triggered (mode=${mode}, state turn ${state.turnNum})`);
}

main();
