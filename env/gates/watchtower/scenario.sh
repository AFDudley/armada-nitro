#!/bin/bash
# Watchtower e2e scenario driver.
#
# Usage: scenario.sh stale | current
#
# "stale": the counterparty challenges with state N while the watcher holds N+1; the watcher
# answers on-chain with N+1.
# "current": the counterparty challenges with state N+1 (the latest); the watcher sends no
# response.
#
# The script:
#   1. Ensures the fixturenet is running (operator-managed deployment at
#      ~/deployments/armada-fixturenet-e12; run-job to bring up the stack if needed).
#   2. Runs the setup (fund a new channel + sign states N and N+1).
#   3. Starts the watcher in the background (subscribes to the adjudicator's
#      ChallengeRegistered event).
#   4. Issues the challenge (stale or current) WHILE the watcher is subscribed.
#   5. Waits for the watcher to finish, then emits its JSON report to stdout.
set -euo pipefail

MODE="${1:-stale}"
DEPLOY_DIR=$HOME/deployments/armada-fixturenet-e12
RPC_URL=http://127.0.0.1:8545
MANIFEST=$DEPLOY_DIR/data/armada_env/manifest.json
STATE_DIR=$DEPLOY_DIR/data/armada_env
POTS_DIR=/src/armada-poc
NITRO_DIR=/src/armada-nitro

# --- 1. Ensure the fixturenet is up: check the host RPC; if it's not answering, run the
#     operator-managed job that brings up the stack (geth + beacon + 4 validators). ---
if ! (curl -s -X POST -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
      -o /dev/null -w '%{http_code}' "$RPC_URL" | grep -q '^200$'); then
  echo "fixturenet RPC not answering; running the deployment job" 1>&2
  ~/bin/laconic-so deployment --dir $DEPLOY_DIR run-job '<job>'
fi

# --- 2. Setup: fund the channel + sign states N (stale) and N+1 (held) ---
run_script() {
  forge script env/gates/watchtower/Scenario.s.sol --sig "$1" \
    --rpc-url "$RPC_URL" --slow --broadcast
}
run_script 'setupChannel()'
# setupChannel writes env/gates/watchtower/held-state.json (the held state, turn N+1) and
# the channel nonce (env/gates/watchtower/channel-nonce).

# --- 3. Start the watcher in the background (subscribes to ChallengeRegistered) ---
# The watcher is the same script the nitro-e2e gate's stage 1 (prepare.ts) is copied into
# the armada-poc repo and run via hardhat. We copy watch.ts into the armada-poc scripts
# directory and run it there. The watcher reads held-state.json and the manifest, subscribes
# to the adjudicator's ChallengeRegistered event, and responds to stale challenges with the
# held state (turn N+1). It exits after processing the event and writes the JSON report
# to stdout.
WATCHER_REPORT=/tmp/watchtower-report.json
echo "starting watcher (subscribes to ChallengeRegistered)"
mkdir -p /src/armada-poc/scripts/gates
cp env/gates/watchtower/watch.ts /src/armada-poc/scripts/gates/watch.ts
(
  cd /src/armada-poc
  HELD_STATE_FILE=$NITRO_DIR/env/gates/watchtower/held-state.json \
  MANIFEST_PATH=$MANIFEST \
  RPC_URL=$RPC_URL \
  USER_KEY=$(cat $STATE_DIR/deployer.key) \
  npx hardhat run scripts/gates/watch.ts
) < /dev/null > $WATCHER_REPORT &
WATCHER_PID=$!

# --- 4. Issue the challenge (stale or current) WHILE the watcher is subscribed ---
echo "issuing challenge ($MODE)"
case "$MODE" in
  stale) run_script 'challengeStale()' ;;
  current) run_script 'challengeCurrent()' ;;
  *) echo "unknown mode: $MODE" 1>&2; exit 1 ;;
esac

# --- 5. Wait for the watcher to finish, then emit the JSON report ---
wait $WATCHER_PID
cat $WATCHER_REPORT