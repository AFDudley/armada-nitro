/**
 * E15a watcher: subscribes to the adjudicator's ChallengeRegistered events for one channel.
 * When a challenge's turn number is lower than the latest fully signed state the watcher holds,
 * it answers on-chain with checkpoint (or the counter-challenge ForceMove requires) using that
 * state, and logs the event block, the response transaction and the latency.
 *
 * Environment variables (set by scenario.sh):
 *   WT_RPC                execution RPC (default http://127.0.1:8545)
 *   WT_MANIFEST           fixturenet manifest path
 *   WT_KEYS               keys directory
 *   WT_USER               user address (participants[0])
 *   WT_CUSTODIAN          hub custodian (participants[1])
 *   WT_APP                consensusApp address
 *   WT_NONCE              channel nonce (uint64)
 *   WT_CHALLENGE_DURATION challenge window (seconds)
 *   WT_DELEGATE_KEY       hub's delegate private key (hex)
 *   WT_HELD_STATE         JSON of the latest fully signed state the watcher holds
 *   WT_KEY_FILE           user's private key filename
 *
 * Emits one JSON object on stdout:
 *   {"detected":bool,"responded":bool,"block":int,"latency_ms":int,"tx_hash":"0x..."}
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
  held: HeldState; keyFile: string;
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
    held: JSON.parse(env("WT_HELD_STATE")),
    keyFile: env("WT_KEY_FILE"),
    usdc: "", adjudicator: "",
  };
  const manifest = JSON.parse(fs.readFileSync(ctx.manifest, "utf8"));
  ctx.adjudicator = manifest.armadaNitro.adjudicator;
  ctx.usdc = manifest.armada.usdc;
  return ctx;
}

// ---- ABI (minimal) ----
const FP = "(address[] participants, uint64 channelNonce, address appDefinition, uint48 challengeDuration)";
const ALLOC = "(bytes32 destination, uint256 amount, uint8 allocationType, bytes metadata)";
const OUTCOME = "(address asset, (uint8 assetType, bytes metadata) assetMetadata, " + ALLOC + "[])";
const VARIOUS = "(uint48 turnNum, bytes appData, " + OUTCOME + " outcome, bool isFinal)";
const SIG = "(uint8 v, bytes32 r, bytes32 s)";
const SIGNED = "(" + VARIOUS + " variablePart, (" + SIG + ") sigs)";

const ABI = [
  "event ChallengeRegistered(bytes32 channelId, uint48 finalizesAt, (" + VARIOUS + " variablePart, (" + SIG + ")[] sigs) candidate)",
  "function checkpoint(" + FP + " fixedPart, (" + VARIOUS + ")[] proof, (" + VARIOUS + " variablePart, (" + SIG + ")[] sigs) candidate)",
  "function challenge(" + FP + " fixedPart, (" + VARIOUS + ")[] proof, (" + VARIOUS + " variablePart, (" + SIG + ")[] sigs) candidate, (" + SIG + ") challengerSig)",
  "event ChallengeCleared(bytes32 channelId, uint48 turnNum)"
];

// ---- hashing: replicate NitroUtils.getChannelId / hashState ----
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

function buildOutcome(ctx: Ctx, held: HeldState): any {
  const empty = "0x";
  const alloc = [
    { destination: "0x0000000000000000000000000000000000000000000000000000000002222",
        amount: held.userAmount, allocationType: 3, metadata: "0x" },
    { destination: ethers.zeroPadValue(ctx.custodian, 32), amount: held.hubAmount, allocationType: 0, metadata: "0x" }
  ];
  return {
    asset: ctx.usdc,
    assetMetadata: { assetType: 0, metadata: "0x" },
    allocations: alloc,
  };
}

function buildVariablePart(ctx: Ctx, held: HeldState): any {
  return {
    turnNum: held.turnNum,
    appData: "0x",
    outcome: [buildOutcome(ctx, held)],
    isFinal: held.isFinal,
  };
}

// Sign the state hash with both participants (user EOA + hub delegate EOA), EIP-191.
function signStateHash(ctx: Ctx, held: HeldState): { variablePart: any; sigs: any[] } {
  const cid = channelId(ctx);
  const variablePart = buildVariablePart(ctx, held);
  const stateHash = encodeKeccak(
    ["bytes32", "bytes", "(address,(uint8,bytes),((bytes32,uint256,uint8,bytes)[])", "uint48", "bool"],
    [cid, variablePart.appData, variablePart.outcome, variablePart.turnNum, variablePart.isFinal]
  );
  const userKey = fs.readFileSync(`${ctx.keysDir}/${ctx.keyFile}`, "utf8").trim();
  const userWallet = new ethers.Wallet(userKey);
  const delegateWallet = new ethers.Wallet(ctx.delegateKey);
  const userSig = userWallet.signMessage(stateHash);
  const delegateSig = delegateWallet.signMessage(stateHash);
  return { variablePart, sigs: [decodeSig(userSig), decodeSig(delegateSig)] };
}

function decodeSig(sig: any): { v: number; r: string; s: string } {
  // ethers 6 signMessage returns a 65-byte hex signature (v byte + r + s)
  const raw = ethers.utils.toArray(sig);
  const v = raw[64];
  const r = "0x" + Buffer.from(raw, 0, 32).toString("hex");
  const s = "0x" + Buffer.from(raw, 32, 64).toString("hex");
  return { v, r, s };
}

async function main() {
  const ctx = loadCtx();
  const cid = channelId(ctx);
  const provider = new ethers.JsonRpcProvider(ctx.rpc);
  const adjudicator = new ethers.Contract(ctx.adjudicator, ABI, provider);

  const report: { detected: boolean; responded: boolean; block: number; latency_ms: number; tx_hash: string } =
    { detected: false, responded: false, block: 0, latency_ms: 0, tx_hash: "" };
  let detectedAt = 0;

  await adjudicator.on("ChallengeRegistered", (event) => {
    if (event.args.channelId === cid) {
      report.detected = true;
      detectedAt = Date.now();
      const evtTurn = event.args.candidate.variablePart.turnNum;
      if (evtTurn < ctx.held.turnNum) {
        // answer with the newer fully signed state (N+1) via checkpoint.
        const signed = signStateHash(ctx, ctx.held);
        const fp = {
          participants: [ctx.user, ctx.custodian],
          channelNonce: ctx.nonce,
          appDefinition: ctx.app,
          challengeDuration: ctx.duration,
        };
        adjudicator.checkpoint(fp, [], { variablePart: signed.variablePart, sigs: signed.sigs })
          .then((tx) => {
            report.block = event.blockNumber;
            report.latency_ms = Date.now() - detectedAt;
            report.tx_hash = tx.hash;
            report.responded = true;
            console.log(JSON.stringify(report));
            setTimeout(() => process.exit(0), 100);
          })
          .catch((e) => {
            report.latency_ms = Date.now() - detectedAt;
            console.log(JSON.stringify(report));
            console.error("checkpoint failed:", e.message);
            setTimeout(() => process.exit(1), 100);
          });
      } else {
        // challenge carries the latest held state's turn -> no response
        report.latency_ms = Date.now() - detectedAt;
        console.log(JSON.stringify(report));
        setTimeout(() => process.exit(0), 100);
      }
    }
  }).catch((e) => { console.error("watch failed:", e.message); process.exit(2); });
}

main();
