// E12 slice 2: replaces lido-core's scripts/scratch/steps/0140-plug-staking-modules.ts.
//
// Upstream 0140 configures the Community Staking Module (CSM) and Curated Module v2 (CMv2) by
// impersonating the Aragon Agent (lib/account.ts's impersonate() -> hardhat_impersonateAccount),
// which real geth rejects. This step makes the exact same calls -- same targets, same calldata,
// same order (docs/tasks/E12-lido-full-scratch.md; proven equal by
// env/lido/tools/capture-0140-calls.ts's diff) -- but each wrapped in an Agent.execute() inside
// one real Aragon DAO vote: TokenManager.forward -> Voting.newVote -> Voting.vote ->
// Voting.executeVote -> Agent.execute. This is the same mechanism
// env/reconciler/modules/lido.py's _resume_via_dao_vote already uses to resume staking.
//
// Everything else (the deployer-signed calls: granting STAKING_MODULE_MANAGE_ROLE, adding all
// four staking modules to the router, the Burner/TriggerableWithdrawalsGateway role grants, the
// ConsolidationMigrator module-id check, setMaxTopUpPerBlockGwei, renouncing
// STAKING_MODULE_MANAGE_ROLE) needs no impersonation upstream either -- the deployer is a real
// key on every network -- so it runs unchanged, directly, exactly as upstream 0140 does it.
import { ethers } from "hardhat";

import {
  Burner,
  ConsolidationMigrator,
  StakingRouter,
  TokenManager,
  TriggerableWithdrawalsGateway,
  Voting,
} from "typechain-types";

import {
  findEventsWithInterfaces,
  HASH_CONSENSUS_FAR_FUTURE_EPOCH,
  WithdrawalCredentialsType,
} from "lib";
import { loadContract, LoadedContract } from "lib/contract";
import { makeTx } from "lib/deploy";
import { streccak } from "lib/keccak";
import { DeploymentState, readNetworkState, Sk } from "lib/state-file";

import { encodeCallScript, ScriptCall } from "scripts/utils/omnibus";

const STAKING_MODULE_MANAGE_ROLE = streccak("STAKING_MODULE_MANAGE_ROLE");
const ZERO_ADDRESS = ethers.ZeroAddress;

// Copied verbatim from scripts/scratch/steps/0140-plug-staking-modules.ts (not exported there).
const EXTERNAL_ACCESS_CONTROL_ABI = [
  "function RESUME_ROLE() view returns (bytes32)",
  "function PAUSE_ROLE() view returns (bytes32)",
  "function grantRole(bytes32 role, address account)",
  "function revokeRole(bytes32 role, address account)",
  "function resume()",
];

const EXTERNAL_HASH_CONSENSUS_ABI = [
  "function getChainConfig() view returns (uint256 slotsPerEpoch, uint256 secondsPerSlot, uint256 genesisTime)",
  "function getFrameConfig() view returns (uint256 initialEpoch, uint256 epochsPerFrame, uint256 fastLaneLengthSlots)",
  "function updateInitialEpoch(uint256 initialEpoch)",
];

const EXTERNAL_CIRCUIT_BREAKER_ABI = [
  "function getPauser(address _pausable) external view returns (address)",
  "function registerPauser(address _pausable, address _newPauser)",
];

const AGENT_EXECUTE_ABI = [
  "function execute(address _target, uint256 _ethValue, bytes _data)",
];

// Staking module parameters -- copied verbatim from upstream 0140.
const NOR_STAKING_MODULE_STAKE_SHARE_LIMIT_BP = 10000; // 100%
const NOR_STAKING_MODULE_PRIORITY_EXIT_SHARE_THRESHOLD_BP = 10000; // 100%
const NOR_STAKING_MODULE_MODULE_FEE_BP = 500; // 5%
const NOR_STAKING_MODULE_TREASURY_FEE_BP = 500; // 5%
const NOR_STAKING_MODULE_MAX_DEPOSITS_PER_BLOCK = 150;
const NOR_STAKING_MODULE_MIN_DEPOSIT_BLOCK_DISTANCE = 25;
const NOR_WITHDRAWAL_TYPE = WithdrawalCredentialsType.WC0x01;

const SDVT_STAKING_MODULE_TARGET_SHARE_BP = 400; // 4%
const SDVT_STAKING_MODULE_PRIORITY_EXIT_SHARE_THRESHOLD_BP = 10000; // 100%
const SDVT_STAKING_MODULE_MODULE_FEE_BP = 800; // 8%
const SDVT_STAKING_MODULE_TREASURY_FEE_BP = 200; // 2%
const SDVT_STAKING_MODULE_MAX_DEPOSITS_PER_BLOCK = 150;
const SDVT_STAKING_MODULE_MIN_DEPOSIT_BLOCK_DISTANCE = 25;
const SDVT_WITHDRAWAL_TYPE = WithdrawalCredentialsType.WC0x01;

const CSM_STAKING_MODULE_NAME = "Community Staking";
const CSM_STAKING_MODULE_TARGET_SHARE_BP = 2000; // 20%
const CSM_STAKING_MODULE_PRIORITY_EXIT_SHARE_THRESHOLD_BP = 2500; // 25%
const CSM_STAKING_MODULE_MODULE_FEE_BP = 800; // 8%
const CSM_STAKING_MODULE_TREASURY_FEE_BP = 200; // 2%
const CSM_STAKING_MODULE_MAX_DEPOSITS_PER_BLOCK = 30;
const CSM_STAKING_MODULE_MIN_DEPOSIT_BLOCK_DISTANCE = 25;
const CSM_WITHDRAWAL_TYPE = WithdrawalCredentialsType.WC0x01;

const CMV2_STAKING_MODULE_NAME = "curated-onchain-v2";
const CMV2_STAKING_MODULE_TARGET_SHARE_BP = 10000; // 100%
const CMV2_STAKING_MODULE_PRIORITY_EXIT_SHARE_THRESHOLD_BP = 10000; // 100%
const CMV2_STAKING_MODULE_MODULE_FEE_BP = 400; // 4%
const CMV2_STAKING_MODULE_TREASURY_FEE_BP = 600; // 6%
const CMV2_STAKING_MODULE_MAX_DEPOSITS_PER_BLOCK = 150;
const CMV2_STAKING_MODULE_MIN_DEPOSIT_BLOCK_DISTANCE = 25;
const CMV2_WITHDRAWAL_TYPE = WithdrawalCredentialsType.WC0x02;

// Real-time poll for vote executability, matching env/reconciler/modules/lido.py's
// _resume_via_dao_vote (a real DAO vote cannot be fast-forwarded on a real chain).
const VOTE_POLL_BUFFER_MS = 120_000;
const VOTE_POLL_INTERVAL_MS = 10_000;

type ExternalDeployArtifact = {
  Accounting?: string;
  CSModule?: string;
  CuratedModule?: string;
  Ejector?: string;
  FeeOracle?: string;
  HashConsensus?: string;
  IdentifiedDVTClusterGate?: string;
  Verifier?: string;
  VettedGate?: string;
};

export type ExternalModuleSetup = {
  accounting: string;
  ejector: string;
  hashConsensus: string;
  module: string;
  moduleLabel: string;
  pausableContracts: { address: string; label: string }[];
};

function getExternalArtifact(
  state: DeploymentState,
  stateKey: Sk,
  moduleLabel: string,
): ExternalDeployArtifact {
  const artifact = state[stateKey]?.deployArtifact as
    | ExternalDeployArtifact
    | undefined;
  if (!artifact) {
    throw new Error(`${moduleLabel} deploy artifact is missing in state`);
  }
  return artifact;
}

function requireArtifactAddress(
  artifact: ExternalDeployArtifact,
  field: keyof ExternalDeployArtifact,
  moduleLabel: string,
): string {
  const value = artifact[field];
  if (!value || value === ZERO_ADDRESS) {
    throw new Error(
      `${moduleLabel} deploy artifact does not contain ${field} address`,
    );
  }
  return value;
}

function optionalArtifactAddress(
  artifact: ExternalDeployArtifact,
  field: keyof ExternalDeployArtifact,
): string | null {
  const value = artifact[field];
  return value && value !== ZERO_ADDRESS ? value : null;
}

// Identical to upstream 0140's getExternalModuleSetup.
export function getExternalModuleSetup(
  state: DeploymentState,
  stateKey: Sk,
  moduleLabel: string,
  moduleField: "CSModule" | "CuratedModule",
  extraPausableFields: {
    field: keyof ExternalDeployArtifact;
    label: string;
  }[] = [],
): ExternalModuleSetup {
  const artifact = getExternalArtifact(state, stateKey, moduleLabel);
  const module = requireArtifactAddress(artifact, moduleField, moduleLabel);
  const pausableContracts: { address: string; label: string }[] = [
    { address: module, label: moduleLabel },
    {
      address: requireArtifactAddress(artifact, "Accounting", moduleLabel),
      label: `${moduleLabel} Accounting`,
    },
    {
      address: requireArtifactAddress(artifact, "FeeOracle", moduleLabel),
      label: `${moduleLabel} FeeOracle`,
    },
    {
      address: requireArtifactAddress(artifact, "Verifier", moduleLabel),
      label: `${moduleLabel} Verifier`,
    },
    {
      address: requireArtifactAddress(artifact, "Ejector", moduleLabel),
      label: `${moduleLabel} Ejector`,
    },
  ];

  for (const { field, label } of extraPausableFields) {
    const address = optionalArtifactAddress(artifact, field);
    if (address) pausableContracts.push({ address, label });
  }

  return {
    accounting: requireArtifactAddress(artifact, "Accounting", moduleLabel),
    ejector: requireArtifactAddress(artifact, "Ejector", moduleLabel),
    hashConsensus: requireArtifactAddress(
      artifact,
      "HashConsensus",
      moduleLabel,
    ),
    module,
    moduleLabel,
    pausableContracts,
  };
}

async function getCurrentEpoch(
  hashConsensus: ethers.Contract,
): Promise<bigint> {
  const latestBlock = await ethers.provider.getBlock("latest");
  if (!latestBlock) throw new Error("Failed to read latest block");

  const [slotsPerEpoch, secondsPerSlot, genesisTime] =
    await hashConsensus.getChainConfig();
  return (
    (BigInt(latestBlock.timestamp) - BigInt(genesisTime)) /
    (BigInt(slotsPerEpoch) * BigInt(secondsPerSlot))
  );
}

/**
 * Deployer-signed role grants upstream 0140's enableExternalModule() makes before its
 * Agent-impersonated calls -- Burner and TriggerableWithdrawalsGateway are deployer-owned, so
 * these need no impersonation upstream either and run directly here too.
 */
async function grantExternalModuleDeployerRoles(
  state: DeploymentState,
  deployer: string,
  setup: ExternalModuleSetup,
): Promise<void> {
  const burner = await loadContract<Burner>(
    "Burner",
    state[Sk.burner].proxy.address,
  );
  await makeTx(
    burner,
    "grantRole",
    [await burner.REQUEST_BURN_MY_STETH_ROLE(), setup.accounting],
    { from: deployer },
  );

  const triggerableWithdrawalsGateway =
    await loadContract<TriggerableWithdrawalsGateway>(
      "TriggerableWithdrawalsGateway",
      state[Sk.triggerableWithdrawalsGateway].address,
    );
  await makeTx(
    triggerableWithdrawalsGateway,
    "grantRole",
    [
      await triggerableWithdrawalsGateway.ADD_FULL_WITHDRAWAL_REQUEST_ROLE(),
      setup.ejector,
    ],
    { from: deployer },
  );
}

/**
 * Builds the exact same Agent-signed calls upstream 0140's enableExternalModule() makes for one
 * module (target, calldata, in order), by reading the same on-chain state -- but without
 * impersonating anything or sending any transaction. A pure function so
 * env/lido/tools/capture-0140-calls.ts can call it directly to build the "what our script would
 * do" side of its diff against upstream's real, captured calls.
 */
export async function buildAgentCalls(
  setup: ExternalModuleSetup,
  agent: string,
  circuitBreakerAddress: string | undefined,
): Promise<ScriptCall[]> {
  const calls: ScriptCall[] = [];

  const module = new ethers.Contract(
    setup.module,
    EXTERNAL_ACCESS_CONTROL_ABI,
    ethers.provider,
  );
  const moduleIf = module.interface;
  const resumeRole = await module.RESUME_ROLE();
  calls.push({
    to: setup.module,
    data: moduleIf.encodeFunctionData("grantRole", [resumeRole, agent]),
  });
  calls.push({
    to: setup.module,
    data: moduleIf.encodeFunctionData("resume", []),
  });
  calls.push({
    to: setup.module,
    data: moduleIf.encodeFunctionData("revokeRole", [resumeRole, agent]),
  });

  const hashConsensus = new ethers.Contract(
    setup.hashConsensus,
    EXTERNAL_HASH_CONSENSUS_ABI,
    ethers.provider,
  );
  const [initialEpoch] = await hashConsensus.getFrameConfig();
  if (BigInt(initialEpoch) === HASH_CONSENSUS_FAR_FUTURE_EPOCH) {
    const currentEpoch = await getCurrentEpoch(hashConsensus);
    calls.push({
      to: setup.hashConsensus,
      data: hashConsensus.interface.encodeFunctionData("updateInitialEpoch", [
        currentEpoch,
      ]),
    });
  }

  if (circuitBreakerAddress) {
    const circuitBreaker = new ethers.Contract(
      circuitBreakerAddress,
      EXTERNAL_CIRCUIT_BREAKER_ABI,
      ethers.provider,
    );
    const circuitBreakerPauser = ethers.getAddress(agent);

    for (const pausable of setup.pausableContracts) {
      const contract = new ethers.Contract(
        pausable.address,
        EXTERNAL_ACCESS_CONTROL_ABI,
        ethers.provider,
      );
      const pauseRole = await contract.PAUSE_ROLE();
      calls.push({
        to: pausable.address,
        data: contract.interface.encodeFunctionData("grantRole", [
          pauseRole,
          circuitBreakerAddress,
        ]),
      });

      const currentPauser = ethers.getAddress(
        await circuitBreaker.getPauser(pausable.address),
      );
      if (currentPauser !== circuitBreakerPauser) {
        calls.push({
          to: circuitBreakerAddress,
          data: circuitBreaker.interface.encodeFunctionData("registerPauser", [
            pausable.address,
            circuitBreakerPauser,
          ]),
        });
      }
    }
  }

  return calls;
}

async function waitForVoteExecutable(
  voting: LoadedContract<Voting>,
  voteId: bigint,
): Promise<void> {
  const voteTime = await voting.voteTime();
  const deadline = Date.now() + Number(voteTime) * 1000 + VOTE_POLL_BUFFER_MS;
  while (!(await voting.canExecute(voteId))) {
    if (Date.now() > deadline) {
      throw new Error(
        `vote ${voteId} (voteTime ${voteTime}s) never became executable`,
      );
    }
    const { promise, resolve } = Promise.withResolvers<void>();
    setTimeout(resolve, VOTE_POLL_INTERVAL_MS);
    await promise;
  }
}

/**
 * Casts and executes one real Aragon DAO vote carrying every Agent-signed call from `agentCalls`
 * (each wrapped in its own Agent.execute(address,uint256,bytes)), the same mechanism
 * env/reconciler/modules/lido.py's _resume_via_dao_vote uses: TokenManager.forward ->
 * Voting.newVote -> Voting.vote -> Voting.executeVote -> Agent.execute.
 */
async function executeAgentCallsViaVote(
  state: DeploymentState,
  deployer: string,
  agentCalls: ScriptCall[],
): Promise<void> {
  if (agentCalls.length === 0) {
    return;
  }

  const agent = state[Sk.appAgent].proxy.address;
  const votingAddress = state[Sk.appVoting].proxy.address;
  const tokenManagerAddress = state[Sk.appTokenManager].proxy.address;

  const agentExecuteIf = new ethers.Interface(AGENT_EXECUTE_ABI);
  const agentScript = encodeCallScript(
    agentCalls.map((call) => ({
      to: agent,
      data: agentExecuteIf.encodeFunctionData("execute", [
        call.to,
        0n,
        call.data,
      ]),
    })),
  );

  console.log(
    `0140-via-vote: casting one Aragon DAO vote carrying ${agentCalls.length} Agent.execute call(s) ` +
      "(replaces hardhat_impersonateAccount):",
  );
  for (const call of agentCalls) {
    console.log(`  Agent[${agent}].execute(${call.to}, 0, ${call.data})`);
  }

  const voting = await loadContract<Voting>("Voting", votingAddress);
  const tokenManager = await loadContract<TokenManager>(
    "TokenManager",
    tokenManagerAddress,
  );

  const votingIf = voting.interface;
  const evmScriptNewVote = encodeCallScript([
    {
      to: votingAddress,
      data: votingIf.encodeFunctionData("newVote(bytes,string)", [
        agentScript,
        "",
      ]),
    },
  ]);

  const receipt = await makeTx(tokenManager, "forward", [evmScriptNewVote], {
    from: deployer,
  });
  const voteId = findEventsWithInterfaces(receipt, "StartVote", [votingIf])[0]
    .args.voteId as bigint;
  console.log(`  vote ${voteId} created`);

  await makeTx(voting, "vote", [voteId, true, false], { from: deployer });
  await waitForVoteExecutable(voting, voteId);
  await makeTx(voting, "executeVote", [voteId], { from: deployer });
  console.log(`  vote ${voteId} executed`);
}

export async function main() {
  const deployer = (await ethers.provider.getSigner()).address;
  const state = readNetworkState({ deployer });

  const stakingRouter = await loadContract<StakingRouter>(
    "StakingRouter",
    state.stakingRouter.proxy.address,
  );

  // Grant STAKING_MODULE_MANAGE_ROLE to deployer (same as upstream 0140).
  await makeTx(
    stakingRouter,
    "grantRole",
    [STAKING_MODULE_MANAGE_ROLE, deployer],
    { from: deployer },
  );

  // Add NOR to StakingRouter (same as upstream 0140).
  await makeTx(
    stakingRouter,
    "addStakingModule",
    [
      state.nodeOperatorsRegistry.deployParameters.stakingModuleName,
      state[Sk.appNodeOperatorsRegistry].proxy.address,
      {
        stakeShareLimit: NOR_STAKING_MODULE_STAKE_SHARE_LIMIT_BP,
        priorityExitShareThreshold:
          NOR_STAKING_MODULE_PRIORITY_EXIT_SHARE_THRESHOLD_BP,
        stakingModuleFee: NOR_STAKING_MODULE_MODULE_FEE_BP,
        treasuryFee: NOR_STAKING_MODULE_TREASURY_FEE_BP,
        maxDepositsPerBlock: NOR_STAKING_MODULE_MAX_DEPOSITS_PER_BLOCK,
        minDepositBlockDistance: NOR_STAKING_MODULE_MIN_DEPOSIT_BLOCK_DISTANCE,
        withdrawalCredentialsType: NOR_WITHDRAWAL_TYPE,
      },
    ],
    { from: deployer },
  );

  // Add Simple DVT to StakingRouter (same as upstream 0140).
  await makeTx(
    stakingRouter,
    "addStakingModule",
    [
      state.simpleDvt.deployParameters.stakingModuleName,
      state[Sk.appSimpleDvt].proxy.address,
      {
        stakeShareLimit: SDVT_STAKING_MODULE_TARGET_SHARE_BP,
        priorityExitShareThreshold:
          SDVT_STAKING_MODULE_PRIORITY_EXIT_SHARE_THRESHOLD_BP,
        stakingModuleFee: SDVT_STAKING_MODULE_MODULE_FEE_BP,
        treasuryFee: SDVT_STAKING_MODULE_TREASURY_FEE_BP,
        maxDepositsPerBlock: SDVT_STAKING_MODULE_MAX_DEPOSITS_PER_BLOCK,
        minDepositBlockDistance: SDVT_STAKING_MODULE_MIN_DEPOSIT_BLOCK_DISTANCE,
        withdrawalCredentialsType: SDVT_WITHDRAWAL_TYPE,
      },
    ],
    { from: deployer },
  );

  const agent = state[Sk.appAgent].proxy.address;
  const agentCalls: ScriptCall[] = [];

  if (state[Sk.sm_CSM]?.proxy?.address) {
    const setup = getExternalModuleSetup(
      state,
      Sk.sm_CSM,
      CSM_STAKING_MODULE_NAME,
      "CSModule",
      [
        { field: "VettedGate", label: `${CSM_STAKING_MODULE_NAME} VettedGate` },
        {
          field: "IdentifiedDVTClusterGate",
          label: `${CSM_STAKING_MODULE_NAME} IdentifiedDVTClusterGate`,
        },
      ],
    );
    await makeTx(
      stakingRouter,
      "addStakingModule",
      [
        CSM_STAKING_MODULE_NAME,
        state[Sk.sm_CSM].proxy.address,
        {
          stakeShareLimit: CSM_STAKING_MODULE_TARGET_SHARE_BP,
          priorityExitShareThreshold:
            CSM_STAKING_MODULE_PRIORITY_EXIT_SHARE_THRESHOLD_BP,
          stakingModuleFee: CSM_STAKING_MODULE_MODULE_FEE_BP,
          treasuryFee: CSM_STAKING_MODULE_TREASURY_FEE_BP,
          maxDepositsPerBlock: CSM_STAKING_MODULE_MAX_DEPOSITS_PER_BLOCK,
          minDepositBlockDistance:
            CSM_STAKING_MODULE_MIN_DEPOSIT_BLOCK_DISTANCE,
          withdrawalCredentialsType: CSM_WITHDRAWAL_TYPE,
        },
      ],
      { from: deployer },
    );
    await grantExternalModuleDeployerRoles(state, deployer, setup);
    agentCalls.push(
      ...(await buildAgentCalls(
        setup,
        agent,
        state[Sk.circuitBreaker]?.address,
      )),
    );
  }

  if (state[Sk.sm_CM]?.proxy?.address) {
    const setup = getExternalModuleSetup(
      state,
      Sk.sm_CM,
      CMV2_STAKING_MODULE_NAME,
      "CuratedModule",
    );
    await makeTx(
      stakingRouter,
      "addStakingModule",
      [
        CMV2_STAKING_MODULE_NAME,
        state[Sk.sm_CM].proxy.address,
        {
          stakeShareLimit: CMV2_STAKING_MODULE_TARGET_SHARE_BP,
          priorityExitShareThreshold:
            CMV2_STAKING_MODULE_PRIORITY_EXIT_SHARE_THRESHOLD_BP,
          stakingModuleFee: CMV2_STAKING_MODULE_MODULE_FEE_BP,
          treasuryFee: CMV2_STAKING_MODULE_TREASURY_FEE_BP,
          maxDepositsPerBlock: CMV2_STAKING_MODULE_MAX_DEPOSITS_PER_BLOCK,
          minDepositBlockDistance:
            CMV2_STAKING_MODULE_MIN_DEPOSIT_BLOCK_DISTANCE,
          withdrawalCredentialsType: CMV2_WITHDRAWAL_TYPE,
        },
      ],
      { from: deployer },
    );
    await grantExternalModuleDeployerRoles(state, deployer, setup);
    agentCalls.push(
      ...(await buildAgentCalls(
        setup,
        agent,
        state[Sk.circuitBreaker]?.address,
      )),
    );

    // ConsolidationMigrator is deployed earlier (0083) with an immutable target module id
    // predicted from deploy params. Verify the id actually assigned to CMv2 matches it (same as
    // upstream 0140).
    const consolidationMigrator = await loadContract<ConsolidationMigrator>(
      "ConsolidationMigrator",
      state[Sk.consolidationMigrator].proxy.address,
    );
    const expectedTargetModuleId = await consolidationMigrator.targetModuleId();
    const cmv2ModuleId = (await stakingRouter.getStakingModuleIds()).at(-1)!;
    const cmv2Module = await stakingRouter.getStakingModule(cmv2ModuleId);
    if (
      cmv2ModuleId !== expectedTargetModuleId ||
      cmv2Module.stakingModuleAddress !== state[Sk.sm_CM].proxy.address ||
      cmv2Module.name !== CMV2_STAKING_MODULE_NAME
    ) {
      throw new Error(
        `CMv2 module id mismatch: assigned id ${cmv2ModuleId} (${cmv2Module.name} at ${cmv2Module.stakingModuleAddress}), ` +
          `but ConsolidationMigrator.targetModuleId() is ${expectedTargetModuleId}. ` +
          `Update [consolidationMigrator].targetModuleId in the scratch deploy params.`,
      );
    }
  }

  // Every Agent-signed call collected above (CSM's, then CMv2's, in that order -- the same order
  // upstream 0140 makes them) goes through one DAO vote instead of impersonation.
  await executeAgentCallsViaVote(state, deployer, agentCalls);

  // Set global per-block top-up ETH cap (LIP-35), required for TopUpGateway-driven top-ups (same
  // as upstream 0140).
  await makeTx(
    stakingRouter,
    "setMaxTopUpPerBlockGwei",
    [state[Sk.stakingRouter].deployParameters.maxTopUpPerBlockGwei],
    { from: deployer },
  );

  // Renounce STAKING_MODULE_MANAGE_ROLE from deployer (same as upstream 0140).
  await makeTx(
    stakingRouter,
    "renounceRole",
    [STAKING_MODULE_MANAGE_ROLE, deployer],
    { from: deployer },
  );

  if (await stakingRouter.hasRole(STAKING_MODULE_MANAGE_ROLE, deployer)) {
    throw new Error("Failed to renounce STAKING_MODULE_MANAGE_ROLE");
  }
}
