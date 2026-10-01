// Watcher (E15): subscribes to the adjudicator's ChallengeRegistered events for one channel.
// When the challenge's turn is lower than the held state's turn, it answers on-chain with the
// newer fully signed state via checkpoint. When the turns match, it sends no response. For each
// answer it logs the event's block, the response transaction and the latency.
//
// Environment:
//   RPC_URL            (default http://127.0.0.1:8545)
//   MANIFEST_PATH      (default ~/deployments/armada-fixturenet-e12/data/armada_env/manifest.json)
//   HELD_STATE_FILE    (default env/gates/watchtower/held-state.json)
//   USER_KEY           (the user's private key; signs the response transaction)
//   CHAIN_ID           (default 31337)
import * as fs from "fs";
import * as pathMod from "path";
import { ethers } from "ethers";
import * as console2 from "console";

// Expand $HOME for tilde paths.
function expandHome(p: string): string {
  if (p.startsWith("~/")) {
    return pathMod.resolve(process.env.HOME || "", p.slice(2));
  }
  return p;
}

const RPC_URL = process.env.RPC_URL || "http://127.0.0.1:8545";
const MANIFEST_PATH = expandHome(process.env.MANIFEST_PATH || "~/deployments/armada-fixturenet-e12/data/armada_env/manifest.json");
const HELD_STATE_FILE = process.env.HELD_STATE_FILE || "env/gates/watchtower/held-state.json";
const USER_KEY = process.env.USER_KEY || "";
const CHAIN_ID = Number(process.env.CHAIN_ID || 31337);

const manifest = JSON.parse(fs.readFileSync(pathMod.resolve(MANIFEST_PATH), "utf8");
const adjudicatorAddress = manifest.armada_nitro.adjudicator;
const heldState = JSON.parse(fs.readFileSync(pathMod.resolve(HELD_STATE_FILE), "utf8");
const heldTurn = Number(heldState.variablePart.turnNum);

// Minimal ABI for the adjudicator: the ChallengeRegistered event plus the response functions.
const ADJUDICATOR_ABI = [
  "event ChallengeRegistered(bytes32 indexed channelId, uint48 finalizesAt, (address[] participants, uint64 channelNonce, address appDefinition, uint48 challengeDuration) fixedPart, (uint48 turnNum, bool isFinal, address[] participants, uint64 channelNonce, address appDefinition, uint48 challengeDuration) candidate)",
  "function checkpoint((address[] participants, uint64 channelNonce, address appDefinition, uint48 challengeDuration) fixedPart, (uint48 turnNum, bool isFinal, address[] participants, uint64 channelNonce, address appDefinition, uint48 challengeDuration)[] proof, (uint48 turnNum, bool isFinal, address[] participants, uint64 channelNonce, address appDefinition, uint48 challengeDuration) candidate)",
  "function challenge((address[] participants, uint64 channelNonce, address appDefinition, uint48 challengeDuration) fixedPart, (uint48 turnNum, bool isFinal, address[] participants, uint64 channelNonce, address appDefinition, uint48 challengeDuration)[] proof, (uint48 turnNum, bool isFinal, uint64 channelNonce, address appDefinition, uint48 challengeDuration) candidate, (uint8 v, bytes32 r, bytes32 s) challengerSig)"
];

interface Report {
  detected: boolean;
  responded: boolean;
  block: number;
  latency_ms: number;
  tx_hash: string;
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL, CHAIN_ID);
  const wallet = new ethers.Wallet(USER_KEY, provider);
  const adjudicator = new ethers.Contract(adjudicatorAddress, ADJUDICATOR_ABI, wallet);

  let report: Report = {
    detected: false,
    responded: false,
    block: 0,
    latency_ms: 0,
    tx_hash: ""
  };

  const onChallengeRegistered = async (event: unknown) => {
    const evt = event as { args: { candidate: { variablePart: { turnNum: number } }; block: number };
    const args = evt.args;
    const challengeTurnNum = Number(args.candidate.variablePart.turnNum);
    const startMs = Date.now();

    if (challengeTurnNum < heldTurn) {
      // Stale challenge (turn N) vs held state (turn N+1): answer on-chain with the newer state.
      const fixedPart = {
        participants: heldState.participants,
        channelNonce: Number(heldState.channelNonce),
        appDefinition: heldState.appDefinition,
        challengeDuration: Number(heldState.challengeDuration)
      };
      const candidate = {
        turnNum: Number(heldState.variablePart.turnNum),
        isFinal: Boolean(heldState.variablePart.isFinal),
        participants: heldState.participants,
        channelNonce: Number(heldState.channelNonce),
        appDefinition: heldState.appDefinition,
        challengeDuration: Number(heldState.challengeDuration)
      };
      const proof: Array<unknown> = [];
      const tx = await adjudicator.checkpoint(fixedPart, proof, candidate);
      await tx; // wait for the response transaction to be mined
      const endMs = Date.now();
      report = {
        detected: true,
        responded: true,
        block: evt.block,
        latency_ms: endMs - startMs,
        tx_hash: tx.hash
      };
      console2.log(`answered stale challenge: tx=${tx.hash} block=${evt.block} latency_ms=${report.latency_ms}`);
    } else {
      // Current challenge (turn == held turn): send no response.
      report = {
        detected: true,
        responded: false,
        block: evt.block,
        latency_ms: 0,
        tx_hash: ""
      };
      console2.log(`challenge at held turn ${heldTurn}: no response`);
    }

    // Exit after processing the event so the scenario can collect the JSON report.
    process.stdout.write(JSON.stringify(report));
    process.exit(0);
  };

  // Subscribe to the ChallengeRegistered event for this channel.
  const filter = {
    address: adjudicatorAddress,
    topic: ethers.utils.formatBytes32(heldState.channelId),
    event: "ChallengeRegistered"
  };
  provider.on(filter, onChallengeRegistered);

  // Safety net: poll for recently-mined events (in case the challenge was mined before subscribe).
  // (The scenario issues the challenge while the watcher is subscribed, so this is a fallback.)
  await adjudicator.query(
    { address: adjudicatorAddress },
    "ChallengeRegistered(bytes32,uint48,(address[],uint64,address,uint48),(uint48,bool,address[],uint64,address,uint48)"
  );
}

main();
