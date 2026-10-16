// ABOUTME: E15 watchtower demo helper -- builds + signs the demo channel states and can send
// ABOUTME: the counterparty's stale challenge; used only by scenario.sh.

// E15 watchtower helper: builds and signs the demo channel's states, and can trigger the
// counterparty's stale challenge on-chain.
//
// Usage (env vars set by scenario.sh):
//   WATCH_RPC        execution RPC (default http://127.0.0.1:8545)
//   MANIFEST_PATH    the fixturenet manifest
//   KEYS_DIR         directory with the test-account private keys (keys/ subdirectory)
//
// Subcommands:
//   build <mode>     mode = "stale" | "current". Builds the demo channel, signs state N
//                    (turn 12) and state N+1 (turn 13), writes held-state.json (N+1 for "stale",
//                    N for "current") and challenge.json (state N + fixedPart + hub key), and
//                    emits {channelId, heldStateFile, challengeFile, heldTurn, challengeTurn}.
//   challenge        Reads challenge.json, computes the hub's challenger signature, and sends the
//                    counterparty's stale challenge on-chain (sent by the hub, testAccounts[1]).

import { ethers } from "ethers";
import * as fs from "node:fs";
import * as path from "node:path";

const RPC = process.env.WATCH_RPC ?? "http://armada-fixturenet-geth:8545";
const MANIFEST = process.env.MANIFEST_PATH ?? "";
const KEYS_DIR = process.env.KEYS_DIR ?? "";

const CHALLENGE_DURATION = 60; // seconds
const TURN_STALE = 12; // state N (the counterparty's stale challenge)
const TURN_NEWER = 13; // state N+1 (the watcher's held state)
const STALE_USER = 150_000_000n;
const STALE_HUB = 50_000_000n;
const NEWER_USER = 160_000_000n; // the newer state gives the user more
const NEWER_HUB = 40_000_000n;

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

const ABI_CODER = ethers.AbiCoder.defaultAbiCoder();

function readManifest() {
  return JSON.parse(fs.readFileSync(MANIFEST, "utf8"));
}

function readKey(addr) {
  const keyFile = path.join(KEYS_DIR, "keys", addr + ".key");
  return fs.readFileSync(keyFile, "utf8").trim();
}

// channelId = keccak256(abi.encode(participants, channelNonce, appDefinition, challengeDuration))
function getChannelId(fp) {
  const enc = ABI_CODER.encode(
    ["address[]", "uint64", "address", "uint48"],
    [fp.participants, fp.channelNonce, fp.appDefinition, fp.challengeDuration],
  );
  return ethers.keccak256(enc);
}

// stateHash = keccak256(abi.encode(channelId, appData, outcome, turnNum, isFinal))
function hashState(channelId, appData, outcome, turnNum, isFinal) {
  const enc = ABI_CODER.encode(
    ["bytes32", "bytes", OUTCOME_T, "uint48", "bool"],
    [channelId, appData, outcome, turnNum, isFinal],
  );
  return ethers.keccak256(enc);
}

// EIP-191: keccak256('\x19Ethereum Signed Message:\n32' + digest)
function prefixedHash(digest) {
  const prefix = ethers.toUtf8Bytes("\x19Ethereum Signed Message:\n32");
  const combined = ethers.concat([prefix, digest]);
  return ethers.keccak256(combined);
}

// challenge digest = keccak256(abi.encode(stateHash, 'forceMove'))
function challengeDigest(stateHash) {
  const enc = ABI_CODER.encode(["bytes32", "string"], [stateHash, "forceMove"]);
  return ethers.keccak256(enc);
}

// Signs `digest` as a participant (a state hash) or as the challenger (challengeDigest's output).
function signWith(key, digest) {
  const signingKey = new ethers.SigningKey(key);
  const sig = signingKey.sign(prefixedHash(digest));
  return { v: sig.v, r: sig.r, s: sig.s };
}

// Builds a fully signed state (user + hub signatures) and its stateHash.
function buildState(
  fixedPart,
  turnNum,
  userAmt,
  hubAmt,
  usdc,
  userKey,
  hubKey,
) {
  const outcome = [
    {
      asset: usdc,
      assetMetadata: { assetType: 0, metadata: "0x" },
      allocations: [
        {
          destination: "0x" + "22".repeat(32),
          amount: userAmt,
          allocationType: 3,
          metadata: "0x",
        },
        {
          destination: ethers.zeroPadValue(fixedPart.participants[1], 32),
          amount: hubAmt,
          allocationType: 0,
          metadata: "0x",
        },
      ],
    },
  ];
  const appData = "0x";
  const isFinal = false;
  const stateHash = hashState(
    getChannelId(fixedPart),
    appData,
    outcome,
    turnNum,
    isFinal,
  );
  const sigs = [signWith(userKey, stateHash), signWith(hubKey, stateHash)];
  return { outcome, appData, turnNum, isFinal, stateHash, sigs };
}

function emit(obj) {
  console.log(JSON.stringify(obj));
}

// --- subcommands ---
async function build(mode) {
  const manifest = readManifest();
  const usdc = manifest.armada.usdc;
  const consensusApp = manifest.armadaNitro.consensusApp;
  const userAddr = manifest.testAccounts[0].address;
  const hubAddr = manifest.testAccounts[1].address;
  const userKey = readKey(userAddr);
  const hubKey = readKey(hubAddr);

  const fixedPart = {
    participants: [userAddr, hubAddr],
    channelNonce: BigInt(Date.now() % 100000000),
    appDefinition: consensusApp,
    challengeDuration: CHALLENGE_DURATION,
  };
  const channelId = getChannelId(fixedPart);

  const stateN = buildState(
    fixedPart,
    TURN_STALE,
    STALE_USER,
    STALE_HUB,
    usdc,
    userKey,
    hubKey,
  );
  const stateN1 = buildState(
    fixedPart,
    TURN_NEWER,
    NEWER_USER,
    NEWER_HUB,
    usdc,
    userKey,
    hubKey,
  );

  // Funding is out of scope here (no payout is checked -- E15b); challenge/checkpoint operate
  // on ForceMove's channel status independent of MultiAssetHolder's holdings.

  // held-state.json: the state the watcher holds.
  //   "stale"   -> state N+1 (turn 13): the newer fully signed state the watcher answers with.
  //   "current" -> state N (turn 12): same turn as the challenge; the watcher sees it, no answer.
  const held = mode === "stale" ? stateN1 : stateN;
  const heldStateJson = {
    participants: fixedPart.participants,
    channelNonce: fixedPart.channelNonce.toString(),
    appDefinition: fixedPart.appDefinition,
    challengeDuration: fixedPart.challengeDuration,
    outcome: held.outcome.map((o) => ({
      asset: o.asset,
      assetMetadata: o.assetMetadata,
      allocations: o.allocations.map((a) => ({
        ...a,
        amount: a.amount.toString(),
      })),
    })),
    appData: held.appData,
    turnNum: held.turnNum,
    isFinal: held.isFinal,
    sigs: held.sigs,
  };
  fs.writeFileSync(
    path.join(".", "held-state.json"),
    JSON.stringify(heldStateJson, null, 2),
  );

  // challenge.json: state N (turn 12) + fixedPart + hub key, for the counterparty's stale challenge.
  const challengeJson = {
    fixedPart: {
      participants: fixedPart.participants,
      channelNonce: fixedPart.channelNonce.toString(),
      appDefinition: fixedPart.appDefinition,
      challengeDuration: fixedPart.challengeDuration,
    },
    stateHash: stateN.stateHash,
    state: {
      outcome: stateN.outcome.map((o) => ({
        asset: o.asset,
        assetMetadata: o.assetMetadata,
        allocations: o.allocations.map((a) => ({
          ...a,
          amount: a.amount.toString(),
        })),
      })),
      appData: stateN.appData,
      turnNum: stateN.turnNum,
      isFinal: stateN.isFinal,
    },
    sigs: stateN.sigs,
    challengerKey: hubKey,
  };
  fs.writeFileSync(
    path.join(".", "challenge.json"),
    JSON.stringify(challengeJson, null, 2),
  );

  return {
    channelId,
    heldStateFile: "held-state.json",
    challengeFile: "challenge.json",
    heldTurn: held.turnNum,
    challengeTurn: stateN.turnNum,
  };
}

async function challenge() {
  const manifest = readManifest();
  const adjudicator = manifest.armadaNitro.adjudicator;
  const c = JSON.parse(
    fs.readFileSync(path.join(".", "challenge.json"), "utf8"),
  );
  const provider = new ethers.JsonRpcProvider(RPC);
  const hubWallet = new ethers.Wallet(c.challengerKey, provider);
  const contract = new ethers.Contract(
    adjudicator,
    [
      `function challenge(${FIXED_PART} fixedPart, ${SIGNED_VARIABLE_PART}[] proof, ${SIGNED_VARIABLE_PART} candidate, ${SIGNATURE} challengerSig)`,
    ],
    hubWallet,
  );

  const fixedPart = {
    participants: c.fixedPart.participants,
    channelNonce: BigInt(c.fixedPart.channelNonce),
    appDefinition: c.fixedPart.appDefinition,
    challengeDuration: c.fixedPart.challengeDuration,
  };
  const candidate = {
    variablePart: {
      outcome: c.state.outcome,
      appData: c.state.appData,
      turnNum: c.state.turnNum,
      isFinal: c.state.isFinal,
    },
    sigs: c.sigs,
  };
  const challengerSig = signWith(c.challengerKey, challengeDigest(c.stateHash));
  const tx = await contract.challenge(fixedPart, [], candidate, challengerSig);
  await tx.wait();
  return { tx_hash: tx.hash };
}

async function main() {
  const cmd = process.argv[2];
  const arg = process.argv[3];
  if (cmd === "build") {
    emit(await build(arg));
  } else if (cmd === "challenge") {
    emit(await challenge());
  } else {
    emit({
      detected: false,
      responded: false,
      block: 0,
      latency_ms: 0,
      tx_hash: "",
    });
  }
}

main().catch((e) => {
  console.error("helper failed:", e);
  emit({
    detected: false,
    responded: false,
    block: 0,
    latency_ms: 0,
    tx_hash: "",
  });
  process.exit(1);
});
