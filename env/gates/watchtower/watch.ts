// ABOUTME: E15 watchtower -- watches one channel for a stale ChallengeRegistered and answers
// ABOUTME: it on-chain with checkpoint, logging the event block, response tx and latency.

// E15 watchtower watcher (ethers 6).
//
// Subscribes to the adjudicator's ChallengeRegistered events for one demo channel. When the
// challenge's turn number is lower than the turn number of the latest fully signed state the
// watcher holds, the watcher answers on-chain with `checkpoint` (or the counter-challenge ForceMove
// requires) using that held state. For each answer it logs the event's block number, the response
// transaction, and the latency between the event and the response.
//
// Inputs (env vars set by scenario.sh):
//   WATCH_RPC            execution RPC (default http://127.0.0.1:8545)
//   WATCH_ADJUDICATOR    the deployed ArmadaNitroAdjudicator address
//   WATCH_CHANNEL        the demo channelId (bytes32, 0x...) -- the watcher filters on this,
//                        the event's indexed topic, so a concurrent challenge on another channel
//                        on the same adjudicator is ignored.
//   WATCH_STATE_FILE     JSON file with the held fully-signed state (fixedPart + variablePart + sigs)
//   WATCH_SIGNER_KEY     private key of the account that sends the answer tx
//   WATCH_WINDOW_S       how long to wait for the challenge event before giving up (default 60)
//
// On the first ChallengeRegistered event for the channel it emits a single JSON line to stdout
// and exits: {detected, responded, block, latency_ms, tx_hash}.

import { ethers } from "ethers";
import * as fs from "node:fs";

const RPC = process.env.WATCH_RPC ?? "http://127.0.0.1:8545";
const ADJUDICATOR = process.env.WATCH_ADJUDICATOR;
const CHANNEL = process.env.WATCH_CHANNEL;
const HELD_FILE = process.env.WATCH_STATE_FILE;
const SIGNER_KEY = process.env.WATCH_SIGNER_KEY;
const WINDOW_S = parseInt(process.env.WATCH_WINDOW_S ?? "60", 10);

// SingleAssetExit = (asset, assetMetadata, allocations[]); AssetMetadata = (assetType, metadata);
// Allocation = (destination, amount, allocationType, metadata). Every struct closes before the
// following `[]`/field -- ethers 6's human-readable tuple parser rejects an unclosed tuple.
const SINGLE_ASSET_EXIT =
  "(address asset, (uint8 assetType, bytes metadata) assetMetadata, " +
  "(bytes32 destination, uint256 amount, uint8 allocationType, bytes metadata)[] allocations)";
const OUTCOME_T = SINGLE_ASSET_EXIT + "[]";
const VARIABLE_PART = `(${OUTCOME_T} outcome, bytes appData, uint48 turnNum, bool isFinal)`;
const SIGNATURE = "(uint8 v, bytes32 r, bytes32 s)";
const SIGNED_VARIABLE_PART = `(${VARIABLE_PART} variablePart, ${SIGNATURE}[] sigs)`;
const FIXED_PART =
  "(address[] participants, uint64 channelNonce, address appDefinition, uint48 challengeDuration)";

const ABI = [
  `event ChallengeRegistered(bytes32 indexed channelId, uint48 finalizesAt, ${SIGNED_VARIABLE_PART}[] proof, ${SIGNED_VARIABLE_PART} candidate)`,
  `function checkpoint(${FIXED_PART} fixedPart, ${SIGNED_VARIABLE_PART}[] proof, ${SIGNED_VARIABLE_PART} candidate)`,
];

function emit(out) {
  console.log(JSON.stringify(out));
}

async function main() {
  const held = JSON.parse(fs.readFileSync(HELD_FILE, "utf8"));
  const provider = new ethers.JsonRpcProvider(RPC);
  const contract = new ethers.Contract(ADJUDICATOR, ABI, provider);

  const fixedPart = {
    participants: held.participants,
    channelNonce: BigInt(held.channelNonce),
    appDefinition: held.appDefinition,
    challengeDuration: held.challengeDuration,
  };
  const heldCandidate = {
    variablePart: {
      outcome: held.outcome,
      appData: held.appData,
      turnNum: held.turnNum,
      isFinal: held.isFinal,
    },
    sigs: held.sigs,
  };
  const heldTurn = Number(held.turnNum);

  let settled = false;

  const finish = (out) => {
    if (settled) return;
    settled = true;
    emit(out);
    process.exit(0);
  };

  const filter = contract.filters.ChallengeRegistered(CHANNEL);
  contract.once(filter, async (payload) => {
    const t0 = Date.now();
    const blockNumber = payload.log.blockNumber;
    const candidateEv = payload.args.candidate;
    const challengeTurn = Number(candidateEv.variablePart.turnNum);

    if (challengeTurn >= heldTurn) {
      // Already at or ahead of the watcher's held state: no answer.
      finish({
        detected: true,
        responded: false,
        block: blockNumber,
        latency_ms: 0,
        tx_hash: "",
      });
      return;
    }

    // Stale challenge: answer on-chain with checkpoint, using the held (newer) state.
    try {
      const wallet = new ethers.Wallet(SIGNER_KEY, provider);
      const signer = contract.connect(wallet);
      const tx = await signer.checkpoint(fixedPart, [], heldCandidate);
      await tx.wait();
      finish({
        detected: true,
        responded: true,
        block: blockNumber,
        latency_ms: Date.now() - t0,
        tx_hash: tx.hash,
      });
    } catch (e) {
      console.error("checkpoint failed:", e);
      finish({
        detected: true,
        responded: false,
        block: blockNumber,
        latency_ms: 0,
        tx_hash: "",
      });
    }
  });

  setTimeout(() => {
    finish({
      detected: false,
      responded: false,
      block: 0,
      latency_ms: 0,
      tx_hash: "",
    });
  }, WINDOW_S * 1000);
}

main().catch((e) => {
  console.error("watch.ts failed:", e);
  emit({
    detected: false,
    responded: false,
    block: 0,
    latency_ms: 0,
    tx_hash: "",
  });
  process.exit(1);
});
