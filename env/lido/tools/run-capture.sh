#!/usr/bin/env bash
# E12 slice 2: runs env/lido/tools/capture-0140-calls.ts inside the image.
#
# "Hardhat's in-process network" (docs/tasks/E12-slices/s2.md) turns out to mean two different
# things depending on which part of lido-core you ask:
#   - lib/account.ts's impersonate() only needs a node whose web3_clientVersion contains
#     "hardhat" or "anvil" (lib/network.ts's getNetworkName) -- either works, and both expose
#     the matching `<name>_impersonateAccount` method.
#   - scripts/utils/staking-modules.ts's deployStakingModules() has a *separate*, stricter check:
#     `if (hardhatNetwork.name === "hardhat")` it skips the external CSM/CMv2 deploy entirely
#     ("no RPC URL for Foundry") -- true only when the Hardhat *task* is literally invoked with
#     `--network hardhat`, which has no RPC endpoint for Foundry's `just deploy-csm`/`deploy-curated`
#     to broadcast against.
# So running the scratch deploy with NETWORK=hardhat, RUN_NETWORK=hardhat (the literal reading of
# "NETWORK=hardhat" in docs/tasks/E12-lido-full-scratch.md/E12-slices/s2.md) never deploys CSM or
# CMv2 at all, and there would be nothing to capture. The fix: run a standalone JSON-RPC server
# and point the migration at it via the built-in "localhost" network (RUN_NETWORK=localhost), so
# deployStakingModules takes its normal external-deploy path. Recorded as a deviation in
# docs/tasks/E12-lido-full-scratch.md.
#
# That server is Anvil, not `npx hardhat node`: Foundry's `forge script --broadcast` pre-flight
# balance/nonce check trips a real Foundry<->Hardhat-Network RPC incompatibility (a `-32602
# "expected a 8 byte hex string"` error on eth_getBalance -- github.com/foundry-rs/foundry#5303
# and #7639) against Hardhat's own node, but not against Anvil, which is what Foundry is built
# and tested against. Everything downstream (impersonation, evm_snapshot/evm_revert/evm_mine, the
# hardhat task runner talking to it over RPC) works identically either way.
#
# CSM's Curated Module v2 deploy estimates ~73.6M gas (see env/reconciler/modules/lido.py's module
# docstring) -- anvil's own --gas-limit (unlike Hardhat Network's hardcoded 30M "hardhat" network
# config) is set high enough here directly; FOUNDRY_BLOCK_GAS_LIMIT raises Foundry's own separate
# `[profile.deploy]` cap (60M) the same way docs/tasks/E12-slices/s1.md flags for the real
# fixturenet. --hardfork osaka matches the real fixturenet (every fork through Osaka at genesis).
set -euo pipefail

LIDO_CORE=/src/lido-core
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPC_URL=http://127.0.0.1:8545
NETWORK_STATE_FILE=/tmp/capture-deployed-state.json

cp "$TOOLS_DIR/../0140-plug-staking-modules-via-vote.ts" "$LIDO_CORE/scripts/0140-plug-staking-modules-via-vote.ts"
cp "$TOOLS_DIR/capture-0140-calls.ts" "$LIDO_CORE/scripts/capture-0140-calls.ts"
rm -f "$NETWORK_STATE_FILE"

cd "$LIDO_CORE"
anvil --host 127.0.0.1 --port 8545 \
  --mnemonic "test test test test test test test test test test test junk" \
  --gas-limit 300000000 \
  --disable-code-size-limit \
  --hardfork osaka \
  >/tmp/capture-anvil.log 2>&1 &
NODE_PID=$!
trap 'kill "$NODE_PID" 2>/dev/null || true; rm -f "$LIDO_CORE/scripts/0140-plug-staking-modules-via-vote.ts" "$LIDO_CORE/scripts/capture-0140-calls.ts"' EXIT

for _ in $(seq 1 60); do
  if curl -s -o /dev/null "$RPC_URL"; then break; fi
  sleep 1
done

# Everything below normally comes from scripts/utils/migration-env.sh's prepare_migration_env,
# invoked by scripts/dao-deploy.sh; this tool calls lib/scratch's applyMigrationScript per step
# directly instead (so it can snapshot/instrument between steps 0135 and 0140), bypassing that
# script, so its defaults are reproduced here explicitly.
export NETWORK=local-devnet
export RUN_NETWORK=localhost
export RPC_URL
export NETWORK_STATE_FILE
export MODE=scratch
export DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export GENESIS_TIME=1639659600
export GAS_PRIORITY_FEE=1
export GAS_MAX_FEE=10
export GAS_LIMIT=16000000
export FOUNDRY_BLOCK_GAS_LIMIT=300000000
export ALLOW_SKIP_STEPS=false
export REFERENCE_OUT="${REFERENCE_OUT:-/tmp/reference-staking-modules.json}"

yarn hardhat compile
yarn hardhat --network localhost run --no-compile scripts/capture-0140-calls.ts
