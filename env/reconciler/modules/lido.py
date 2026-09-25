"""lido module: deploy Lido core (stETH, wstETH, locator, oracle contracts) from scratch over
this environment's fixturenet, using lido-core's own published scratch deploy
(scripts/dao-deploy.sh -> scripts/run-migration.sh -> scripts/scratch/steps/*.ts, driven by
scripts/scratch/deploy-params-fixturenet.toml and steps-fixturenet.json, both documented,
overridable inputs -- see their own docstrings/comments). The oracle is deployed but left
unconfigured: no HashConsensus members, no reports, no price injection. See
docs/ENVIRONMENT.md §6 (lido row) and docs/tasks/E5-lido.md.

Two deviations from lido-core's shipped scripts as published (recorded here with evidence, per
the worker protocol's "stop and report a wrong fact" rule -- narrow, specific points, not the
scratch deploy as a whole, since everything else about it runs unmodified):

1. env/lido/steps-fixturenet.json (STEPS_FILE) drops the shipped scripts/scratch/steps.json's
   last three entries -- 0135-deploy-staking-modules, 0140-plug-staking-modules,
   0150-transfer-roles. Confirmed by reproduction (env/lido/steps-fixturenet.json's own comment
   has the full trace): 0135 unconditionally clones lidofinance/community-staking-module and
   deploys Community Staking Module + Curated Module v2 for any network but hardhat's in-process
   one; 0140 then needs to act as the Aragon Agent to configure them, via lib/account.ts's
   impersonate() -- an Anvil/Hardhat-only cheatcode. This environment's hardhat network needs an
   explicit deployer private key (to sign *real* transactions at all), which makes Hardhat use
   its LocalAccountsProvider instead of forwarding to the node -- impersonation fails with
   HardhatError HH103 ("Account ... is not managed by the node") before the node (real geth, or
   even this reproduction's own Anvil) is ever asked to impersonate anything. Neither module is
   named in docs/scratch-deploy.md or in docs/tasks/E5-lido.md's Goal (stETH, wstETH, locator,
   oracle contracts only); both are out of scope per that brief's own "staking modules beyond
   what the scratch deploy creates" line. 0150 is dropped too, but only because it is now
   pointless: it hands OZ AccessControl admin roles and OssifiableProxy admin control from the
   deployer to the Agent, and none of docs/ENVIRONMENT.md §6's lido postconditions read who
   holds those roles.

2. env/lido/deploy-params-fixturenet.toml (SCRATCH_DEPLOY_CONFIG) is lido-core's own
   scripts/scratch/deploy-params-testnet.toml, byte-for-byte, with one vesting.holders address
   renamed. See that file's own header comment for the full "why" (short version: Lido.resume()
   is Agent-only, only Aragon Voting can drive the Agent, and creating a vote needs the deployer
   to hold LDO -- the shipped config gives 76% of it to a placeholder nobody here holds the key
   for).

A gas-limit finding recorded for the next worker's benefit, not acted on here (moot once (1)
above skips the step it applied to): lidofinance/community-staking-module's own foundry.toml
caps `[profile.deploy]` at block_gas_limit = 60_000_000 (with their own comment acknowledging
"unknown problem of too high estimated gas usage" since a forge-std upgrade) while its Curated
Module v2 deploy alone estimates ~73.6M gas -- reproduced as a hard failure *unaffected* by the
underlying chain's own configured gas limit (confirmed unchanged at both this fixturenet's real
default, ethereum-genesis-generator's GENESIS_GASLIMIT=200,000,000, and an Anvil test explicitly
started with --gas-limit 200000000); `FOUNDRY_BLOCK_GAS_LIMIT` would override it if that module
is ever deployed here on purpose.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path

from reconciler.context import CastError, Context, resolve_target_mode, to_int

_LIDO_CORE = Path("/src/lido-core")

# env/reconciler/modules/lido.py -> env/lido (two directories up, then into lido/).
_ENV_LIDO = Path(__file__).resolve().parents[2] / "lido"
_SCRATCH_DEPLOY_CONFIG = _ENV_LIDO / "deploy-params-fixturenet.toml"
_STEPS_SOURCE = _ENV_LIDO / "steps-fixturenet.json"

# lib/scratch.ts's loadSteps always resolves STEPS_FILE as `scripts/${STEPS_FILE}` under the
# process's cwd (/src/lido-core here) -- unlike SCRATCH_DEPLOY_CONFIG/NETWORK_STATE_FILE, it
# cannot be pointed at an absolute path outside the checkout, so this module's copy has to live
# under lido-core's own scripts/ dir. Written fresh into the ephemeral job container's
# filesystem each run (discarded when the job exits, like every other module's use of the
# image's checkouts for scratch output -- e.g. armada.py's circuits fetch, aave.py's
# reports/aave-market.json) -- never committed into lido-core, so this is not an edit to it.
_STEPS_DEST = _LIDO_CORE / "scripts" / "env-fixturenet-steps.json"
_STEPS_FILE_ARG = "env-fixturenet-steps.json"

# ethpandaops/ethereum-genesis-generator 6.2.1's own output layout (its entrypoint writes
# `grep DEPOSIT_CONTRACT_ADDRESS /data/metadata/config.yaml | cut -d " " -f2 >
# /data/metadata/deposit_contract.txt`); bind-mounted read-only into this job's container by
# stack/compose-jobs/docker-compose-armada-env-reconcile.yml (armada_fixturenet_genesis volume,
# the same one E1's armada-fixturenet-genesis service writes into). Per docs/tasks/E5-lido.md:
# "Use the fixturenet's genesis deposit contract, recorded by E1."
_DEPOSIT_CONTRACT_FILE = Path("/genesis/metadata/deposit_contract.txt")

# anvil/hardhat mnemonic index 0: docs/ENVIRONMENT.md §2's fixed premine account 0, and the only
# deployer scripts/scratch/steps/0000-populate-deploy-artifact-from-env.ts's DEFAULT_TEST_DEPLOYER
# constant also names. Matches ctx.deployer_key/ctx.deployer_address (env/reconciler/context.py).
# "local-devnet" is a network hardhat.config.ts defines for exactly this purpose -- scripts/
# utils/staking-modules.ts's CHAINS tuple names it a first-class supported chain alongside
# "mainnet" and "hoodi" -- with `accounts: [LOCAL_DEVNET_PK]` for real-key signing.
_HARDHAT_NETWORK_NAME = "local-devnet"

# lib/state-file.ts's Sk enum keys this module reads out of the state file
# (env/lido module's own copy, kept as <state>/lido-deployed.json per docs/tasks/E5-lido.md).
_SK_LIDO_LOCATOR = "lidoLocator"
_SK_APP_LIDO = "app:lido"
_SK_WSTETH = "wstETH"
_SK_ACCOUNTING_ORACLE = "accountingOracle"
_SK_HASH_CONSENSUS_AO = "hashConsensusForAccountingOracle"
_SK_HASH_CONSENSUS_VEB = "hashConsensusForValidatorsExitBusOracle"
_SK_APP_AGENT = "app:aragon-agent"
_SK_APP_VOTING = "app:aragon-voting"
_SK_APP_TOKEN_MANAGER = "app:aragon-token-manager"
_SK_GAS_USED = "scratchDeployGasUsed"

# Aragon EVMScriptRegistry's registered executor id for CallsScript
# (node_modules/@aragon/os/contracts/evmscript/executors/CallsScript.sol's doc comment: "specId
# (uint32)"; 1 is CallsScript's fixed, universal registration id across every Aragon deployment).
_CALLS_SCRIPT_SPEC_ID = (1).to_bytes(4, "big")

# Vote timing is read live from Voting.voteTime() (see _resume_via_dao_vote) -- this is only a
# poll-loop safety margin on top of it, for block-timestamp/mining jitter.
_VOTE_POLL_BUFFER_SECONDS = 120
_VOTE_POLL_INTERVAL_SECONDS = 10

# Live proof (submit 1 ETH -> mints stETH) runs once, the first time this run recognizes the
# deployment -- mirrors weth.py/usdc.py/aave.py's _FRESHLY_RECOGNIZED.
_FRESHLY_RECOGNIZED = ("deployed", "adopted")
_ONE_ETH_WEI = 10**18


def _uint(cast_output: str) -> int:
    # `cast call ...(uintN)` pretty-prints large values as "1000000000000000000 [1e18]".
    return to_int(cast_output.split()[0])


def _run_dao_deploy(env: dict[str, str]) -> None:
    full_env = {**os.environ, **env}
    result = subprocess.run(
        ["bash", "scripts/dao-deploy.sh"],
        capture_output=True,
        text=True,
        cwd=str(_LIDO_CORE),
        env=full_env,
    )
    if result.returncode != 0:
        raise CastError(
            "scripts/dao-deploy.sh failed (exit "
            f"{result.returncode}):\nstdout tail:\n{result.stdout.strip()[-4000:]}\n"
            f"stderr tail:\n{result.stderr.strip()[-4000:]}"
        )


def _read_deposit_contract() -> str:
    if not _DEPOSIT_CONTRACT_FILE.exists():
        raise CastError(
            f"{_DEPOSIT_CONTRACT_FILE} not found -- expected the armada_fixturenet_genesis volume "
            "mounted read-only into this job (stack/compose-jobs/docker-compose-armada-env-reconcile.yml)"
        )
    return _DEPOSIT_CONTRACT_FILE.read_text().strip()


def _read_state(state_file: Path) -> dict:
    return json.loads(state_file.read_text())


def _proxy_address(state: dict, key: str) -> str:
    return state[key]["proxy"]["address"]


def _cast_calldata(*args: str) -> str:
    # Offline ABI encoding only (function selector/args, no chain access) -- cast's `calldata`
    # subcommand takes no --rpc-url, unlike every Context.cast() call, so this runs `cast`
    # directly rather than through ctx.cast().
    result = subprocess.run(["cast", "calldata", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise CastError(f"cast calldata {args} failed (exit {result.returncode}): {result.stderr.strip()}")
    return result.stdout.strip()


def _encode_calls_script(actions: list[tuple[str, bytes]]) -> str:
    """Aragon's CallsScript encoding (node_modules/@aragon/os/contracts/evmscript/executors/
    CallsScript.sol): specId (4 bytes) then, per action, `to` (20 bytes) + calldata length
    (4-byte big-endian uint32) + calldata."""
    parts = [_CALLS_SCRIPT_SPEC_ID]
    for to, calldata in actions:
        parts.append(bytes.fromhex(to[2:].rjust(40, "0").lower()))
        parts.append(len(calldata).to_bytes(4, "big"))
        parts.append(calldata)
    return "0x" + b"".join(parts).hex()


def _resume_via_dao_vote(ctx: Context, state: dict, lido: str) -> int:
    """Casts and executes a real Aragon DAO vote -- through TokenManager.forward ->
    Voting.newVote -> Voting.vote -> Voting.executeVote -> Agent.execute -> Lido.resume() -- using
    the deployer's LDO holding from env/lido/deploy-params-fixturenet.toml (see module docstring).
    Returns the total gas spent. Every call here is logged (`print`) so its exact composition is
    reported, per docs/tasks/E5-lido.md ("Report the exact call")."""
    agent = _proxy_address(state, _SK_APP_AGENT)
    voting = _proxy_address(state, _SK_APP_VOTING)
    token_manager = _proxy_address(state, _SK_APP_TOKEN_MANAGER)

    resume_calldata = bytes.fromhex(_cast_calldata("resume()")[2:])
    execute_calldata = bytes.fromhex(
        _cast_calldata("execute(address,uint256,bytes)", lido, "0", "0x" + resume_calldata.hex())[2:]
    )
    resume_script = _encode_calls_script([(agent, execute_calldata)])
    new_vote_calldata = bytes.fromhex(_cast_calldata("newVote(bytes,string)", resume_script, "")[2:])
    vote_script = _encode_calls_script([(voting, new_vote_calldata)])

    print(
        "lido: resuming staking via a real Aragon DAO vote (Lido.resume() is Agent-only; only "
        "Voting can drive the Agent -- see module docstring). Exact calls:\n"
        f"  1. TokenManager[{token_manager}].forward(bytes) -- script: Voting[{voting}]"
        f".newVote(bytes,string) with executionScript: Agent[{agent}].execute(address,uint256,bytes)"
        f"({lido}, 0, Lido.resume())\n"
        f"  2. Voting[{voting}].vote(uint256,bool,bool)(voteId, true, false)\n"
        f"  3. Voting[{voting}].executeVote(uint256)(voteId)"
    )

    vote_id = to_int(ctx.cast("call", voting, "votesLength()(uint256)"))
    total_gas = 0

    receipt = ctx.send(token_manager, "forward(bytes)", vote_script)
    total_gas += to_int(receipt["gasUsed"])

    receipt = ctx.send(voting, "vote(uint256,bool,bool)", str(vote_id), "true", "false")
    total_gas += to_int(receipt["gasUsed"])

    vote_time = to_int(ctx.cast("call", voting, "voteTime()(uint64)"))
    deadline = time.monotonic() + vote_time + _VOTE_POLL_BUFFER_SECONDS
    while ctx.cast("call", voting, "canExecute(uint256)(bool)", str(vote_id)) != "true":
        if time.monotonic() > deadline:
            raise ctx.fail(
                f"vote {vote_id} (voteTime {vote_time}s) never became executable "
                f"(waited {vote_time + _VOTE_POLL_BUFFER_SECONDS}s)"
            )
        time.sleep(_VOTE_POLL_INTERVAL_SECONDS)

    receipt = ctx.send(voting, "executeVote(uint256)", str(vote_id))
    total_gas += to_int(receipt["gasUsed"])

    if ctx.cast("call", lido, "isStakingPaused()(bool)") != "false":
        raise ctx.fail(f"Lido[{lido}].isStakingPaused() is still true after executing vote {vote_id}")

    return total_gas


def observe(ctx: Context) -> dict | None:
    return ctx.manifest.get("lido")


def apply(ctx: Context, observed: dict | None) -> tuple[str, int]:
    mode, params = resolve_target_mode(ctx.target["lido"])

    if mode == "adopt":
        locator = params["locator"]
        action = "present" if observed and observed.get("locator") == locator else "adopted"
        ctx.manifest["lido"] = {
            "locator": locator,
            "stETH": params["stETH"],
            "wstETH": params["wstETH"],
            "accountingOracle": params["accountingOracle"],
            "hashConsensus": params["hashConsensus"],
        }
        ctx.manifest.setdefault("assets", {})["wstETH"] = params["wstETH"]
        return action, 0

    # mode == "deploy": a locator already on record is never redeployed.
    if observed and observed.get("locator"):
        return "present", 0

    deposit_contract = _read_deposit_contract()
    chain_id = ctx.target["network"]["chainId"]
    state_file = ctx.state_dir / "lido-deployed.json"
    # scripts/utils/migration-env.sh's MODE=scratch branch does `rm -f "$NETWORK_STATE_FILE"`
    # unconditionally -- harmless here since apply() only reaches this point on a first deploy
    # (the "observed" guard above already returned "present" otherwise), so there is nothing to
    # lose; matches every other module's "a first run is the only run that deploys" contract.

    _STEPS_DEST.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(_STEPS_SOURCE, _STEPS_DEST)

    env = {
        "NETWORK": _HARDHAT_NETWORK_NAME,
        "RPC_URL": ctx.rpc_url,
        "LOCAL_DEVNET_PK": ctx.deployer_key,
        "LOCAL_DEVNET_CHAIN_ID": str(chain_id),
        "MODE": "scratch",
        "DEPLOYER": ctx.deployer_address,
        "DEPOSIT_CONTRACT": deposit_contract,
        "SCRATCH_DEPLOY_CONFIG": str(_SCRATCH_DEPLOY_CONFIG),
        "STEPS_FILE": _STEPS_FILE_ARG,
        "NETWORK_STATE_FILE": str(state_file),
    }
    _run_dao_deploy(env)

    if not state_file.exists():
        raise ctx.fail(f"scripts/dao-deploy.sh did not write {state_file}")
    state = _read_state(state_file)

    locator = _proxy_address(state, _SK_LIDO_LOCATOR)
    steth = _proxy_address(state, _SK_APP_LIDO)
    wsteth = state[_SK_WSTETH]["address"]
    accounting_oracle = _proxy_address(state, _SK_ACCOUNTING_ORACLE)
    hash_consensus = [
        state[_SK_HASH_CONSENSUS_AO]["address"],
        state[_SK_HASH_CONSENSUS_VEB]["address"],
    ]

    total_gas = to_int(state[_SK_GAS_USED])

    if ctx.cast("call", steth, "isStakingPaused()(bool)") == "true":
        total_gas += _resume_via_dao_vote(ctx, state, steth)

    ctx.manifest["lido"] = {
        "locator": locator,
        "stETH": steth,
        "wstETH": wsteth,
        "accountingOracle": accounting_oracle,
        "hashConsensus": hash_consensus,
    }
    ctx.manifest.setdefault("assets", {})["wstETH"] = wsteth
    ctx.manifest.setdefault("gasUsed", {})
    ctx.manifest["gasUsed"]["lido"] = ctx.manifest["gasUsed"].get("lido", 0) + total_gas
    return "deployed", total_gas


def verify(ctx: Context, action: str) -> None:
    lido = ctx.manifest.get("lido")
    if not lido:
        raise ctx.fail("no lido recorded; run without --verify-only first")
    wsteth = ctx.manifest.get("assets", {}).get("wstETH")
    if not wsteth:
        raise ctx.fail("no assets.wstETH recorded; run without --verify-only first")

    wsteth_steth = ctx.cast("call", wsteth, "stETH()(address)")
    if wsteth_steth.lower() != lido["stETH"].lower():
        raise ctx.fail(f"wstETH.stETH() = {wsteth_steth}, expected {lido['stETH']}")

    rate = _uint(ctx.cast("call", wsteth, "stEthPerToken()(uint256)"))
    if rate != _ONE_ETH_WEI:
        raise ctx.fail(f"wstETH.stEthPerToken() = {rate}, expected {_ONE_ETH_WEI} (1e18, no oracle report ever)")

    # Every HashConsensus has zero members -- checked every run (not gated by action), including
    # under --verify-only: docs/tasks/E5-lido.md's negative case is "an oracle member added in a
    # scratch deployment makes --verify-only fail on the 'zero members' postcondition".
    for hash_consensus in lido["hashConsensus"]:
        members_line = ctx.cast("call", hash_consensus, "getMembers()(address[],uint256[])").splitlines()[0].strip()
        if members_line != "[]":
            raise ctx.fail(f"HashConsensus[{hash_consensus}].getMembers() returned members {members_line}, expected none")

    if action not in _FRESHLY_RECOGNIZED:
        return  # stETH()/stEthPerToken()/zero-members (just checked) already prove correctness

    # One-time live proof: submit 1 ETH, expect it to mint stETH 1:1 (stEthPerToken() == 1e18,
    # just checked, and no oracle report has ever run).
    steth = lido["stETH"]
    deployer = ctx.deployer_address
    balance_before = _uint(ctx.cast("call", steth, "balanceOf(address)(uint256)", deployer))
    ctx.send(steth, "submit(address)", "0x0000000000000000000000000000000000000000", "--value", "1ether")
    balance_after = _uint(ctx.cast("call", steth, "balanceOf(address)(uint256)", deployer))

    minted = balance_after - balance_before
    if minted != _ONE_ETH_WEI:
        raise ctx.fail(f"submit(1 ETH) minted {minted} stETH, expected exactly {_ONE_ETH_WEI} (1 stETH)")
