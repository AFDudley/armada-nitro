// E12 slice 2: proves env/lido/0140-plug-staking-modules-via-vote.ts makes the same Agent calls
// (same targets, same calldata, same order) as upstream lido-core's
// scripts/scratch/steps/0140-plug-staking-modules.ts.
//
// Runs inside the image against a standalone Anvil JSON-RPC server (env/lido/tools/run-capture.sh
// starts it) so step 0135 (scripts/utils/staking-modules.ts's deployStakingModules) takes its
// normal, RPC-driven external-deploy path instead of the in-process "hardhat" network's early
// return ("In-memory 'hardhat' network detected: skipping external CSM/CMv2 deployment") -- see
// that run-capture.sh header comment for the full explanation of why NETWORK=hardhat alone is not
// "hardhat's in-process network" for this purpose.
//
// Method (no edit to lido-core):
//   1. Run the unmodified scratch deploy steps up to (not including) 0140, via lib/scratch's own
//      applyMigrationScript -- exactly what lib/scratch's deployScratchProtocol does, stopping
//      short of 0140 so we can instrument around it.
//   2. Snapshot the chain (evm_snapshot).
//   3. Instrument ethers.provider.send to record every eth_sendTransaction whose `from` is the
//      Aragon Agent -- (target, calldata) -- while upstream 0140 (still the real, unmodified
//      file) runs via the same applyMigrationScript/impersonate() path it always uses. That is
//      list (a).
//   4. Revert the snapshot (undo 0140's on-chain effects, back to the identical post-0135 state
//      it read from).
//   5. Call our own script's exported buildAgentCalls() for the same CSM/CMv2 setups, against
//      that same reverted state, with no impersonation and no transaction sent. That is list (b).
//   6. Diff (a) against (b); also dump the staking router's module list (env/lido/
//      reference-staking-modules.json's source, per docs/tasks/E12-slices/s4.md).
import { writeFileSync } from "node:fs";

import { ethers } from "hardhat";

import { StakingRouter } from "typechain-types";

import { applyMigrationScript, loadSteps, resolveMigrationFile } from "lib/scratch";
import { loadContract } from "lib/contract";
import { DeploymentState, readNetworkState, Sk } from "lib/state-file";

import { buildAgentCalls, ExternalModuleSetup, getExternalModuleSetup } from "./0140-plug-staking-modules-via-vote";

type Call = { to: string; data: string };

const STEP_0140 = "scratch/steps/0140-plug-staking-modules";

// Every unmodified upstream step up to (not including) 0140, read live from lido-core's own
// scripts/scratch/steps.json rather than copied here by hand, so this never drifts from it.
function stepsBefore0140(): string[] {
  const steps = loadSteps(process.env.STEPS_FILE || "scratch/steps.json");
  const index = steps.indexOf(STEP_0140);
  if (index === -1) {
    throw new Error(`${STEP_0140} not found in steps file`);
  }
  return steps.slice(0, index);
}

function moduleSetups(
  state: DeploymentState,
): { label: string; setup: ExternalModuleSetup }[] {
  const setups: { label: string; setup: ExternalModuleSetup }[] = [];
  if (state[Sk.sm_CSM]?.proxy?.address) {
    setups.push({
      label: "CSM",
      setup: getExternalModuleSetup(state, Sk.sm_CSM, "Community Staking", "CSModule", [
        { field: "VettedGate", label: "Community Staking VettedGate" },
        { field: "IdentifiedDVTClusterGate", label: "Community Staking IdentifiedDVTClusterGate" },
      ]),
    });
  }
  if (state[Sk.sm_CM]?.proxy?.address) {
    setups.push({
      label: "CMv2",
      setup: getExternalModuleSetup(state, Sk.sm_CM, "curated-onchain-v2", "CuratedModule"),
    });
  }
  return setups;
}

function normalize(call: Call): Call {
  return { to: ethers.getAddress(call.to), data: call.data.toLowerCase() };
}

function diffCalls(a: Call[], b: Call[]): string[] {
  const na = a.map(normalize);
  const nb = b.map(normalize);
  const lines: string[] = [];
  const max = Math.max(na.length, nb.length);
  for (let i = 0; i < max; i++) {
    const ca = na[i];
    const cb = nb[i];
    if (!ca) {
      lines.push(`+ [${i}] (b only) to=${cb.to} data=${cb.data}`);
    } else if (!cb) {
      lines.push(`- [${i}] (a only) to=${ca.to} data=${ca.data}`);
    } else if (ca.to !== cb.to || ca.data !== cb.data) {
      lines.push(`- [${i}] (a) to=${ca.to} data=${ca.data}`);
      lines.push(`+ [${i}] (b) to=${cb.to} data=${cb.data}`);
    }
  }
  return lines;
}

async function dumpReferenceStakingModules(
  stakingRouter: StakingRouter,
  contractNameByAddress: Record<string, string>,
  outPath: string,
  command: string,
) {
  const ids: bigint[] = await stakingRouter.getStakingModuleIds();
  const modules = [];
  for (const id of ids) {
    const m = await stakingRouter.getStakingModule(id);
    const address = ethers.getAddress(m.stakingModuleAddress);
    const contractName = contractNameByAddress[address];
    if (!contractName) {
      throw new Error(`no known contract name for staking module address ${address} (id ${id}, name ${m.name})`);
    }
    modules.push({ id: Number(id), name: m.name, stakingModuleAddress: address, contractName });
  }
  writeFileSync(
    outPath,
    JSON.stringify(
      {
        _comment:
          "Reference staking-router module list from a full scratch deploy against a standalone " +
          "Anvil JSON-RPC server (env/lido/tools/run-capture.sh), so step 0135's external " +
          "CSM/CMv2 deploy runs for real. Produced by env/lido/tools/capture-0140-calls.ts. Used " +
          "by env/reconciler/modules/lido.py's verify() to check the fixturenet's staking router " +
          "lists the same modules (docs/tasks/E12-slices/s4.md).",
        command,
        modules,
      },
      null,
      2,
    ),
  );
  console.log(`wrote ${outPath}`);
}

async function main() {
  const deployer = (await ethers.provider.getSigner()).address;

  for (const step of stepsBefore0140()) {
    await applyMigrationScript(resolveMigrationFile(step));
    await ethers.provider.send("evm_mine", []);
  }

  const preState = readNetworkState({ deployer });
  const agent = preState[Sk.appAgent].proxy.address;
  const circuitBreaker = preState[Sk.circuitBreaker]?.address;
  const setups = moduleSetups(preState);
  if (setups.length === 0) {
    throw new Error("0135 did not deploy CSM or CMv2 -- nothing to capture");
  }

  // NOR and SimpleDVT are both proxies in front of the same NodeOperatorsRegistry contract
  // (scripts/scratch/steps/0120-post-locator-initializers.ts loads SimpleDVT's proxy as
  // "NodeOperatorsRegistry" too); CSM/CMv2's contract names come from their own deploy artifact
  // field names ("CSModule"/"CuratedModule").
  const contractNameByAddress: Record<string, string> = {
    [ethers.getAddress(preState[Sk.appNodeOperatorsRegistry].proxy.address)]: "NodeOperatorsRegistry",
    [ethers.getAddress(preState[Sk.appSimpleDvt].proxy.address)]: "NodeOperatorsRegistry",
  };
  for (const { label, setup } of setups) {
    contractNameByAddress[ethers.getAddress(setup.module)] = label === "CSM" ? "CSModule" : "CuratedModule";
  }

  const stakingRouter = await loadContract<StakingRouter>("StakingRouter", preState.stakingRouter.proxy.address);

  const snapshotId = (await ethers.provider.send("evm_snapshot", [])) as string;

  // (a) instrument: record every eth_sendTransaction sent as the Agent while upstream's real,
  // unmodified 0140 runs (impersonation works here -- see module header comment).
  const captured: Call[] = [];
  const originalSend = ethers.provider.send.bind(ethers.provider);
  ethers.provider.send = (async (method: string, params?: unknown[]) => {
    if (method === "eth_sendTransaction" && Array.isArray(params) && params[0]) {
      const tx = params[0] as { from?: string; to?: string; data?: string };
      if (tx.from && tx.to && ethers.getAddress(tx.from) === ethers.getAddress(agent)) {
        captured.push({ to: tx.to, data: tx.data ?? "0x" });
      }
    }
    return originalSend(method, params ?? []);
  }) as typeof ethers.provider.send;

  try {
    await applyMigrationScript(resolveMigrationFile(STEP_0140));
  } finally {
    ethers.provider.send = originalSend;
  }

  await dumpReferenceStakingModules(
    stakingRouter,
    contractNameByAddress,
    process.env.REFERENCE_OUT || "/tmp/reference-staking-modules.json",
    "env/lido/tools/run-capture.sh (NETWORK=local-devnet RUN_NETWORK=localhost yarn hardhat " +
      "--network localhost run --no-compile scripts/capture-0140-calls.ts)",
  );

  // Undo 0140's on-chain effects: reads below must see exactly what upstream 0140 saw.
  await ethers.provider.send("evm_revert", [snapshotId]);
  await ethers.provider.send("evm_mine", []);

  // (b) build the same calls via our own via-vote script's pure builder, from the same state.
  const built: Call[] = [];
  for (const { setup } of setups) {
    const calls = await buildAgentCalls(setup, agent, circuitBreaker);
    built.push(...calls.map((c) => ({ to: c.to, data: c.data as string })));
  }

  console.log(`\n=== (a) upstream 0140's captured Agent calls (${captured.length}) ===`);
  captured.forEach((c, i) => console.log(`[${i}] to=${c.to} data=${c.data}`));

  console.log(`\n=== (b) our via-vote script's built Agent calls (${built.length}) ===`);
  built.forEach((c, i) => console.log(`[${i}] to=${c.to} data=${c.data}`));

  const diff = diffCalls(captured, built);
  console.log(`\n=== diff (a) vs (b): ${diff.length === 0 ? "empty" : `${diff.length} line(s)`} ===`);
  diff.forEach((l) => console.log(l));

  if (diff.length > 0) {
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
