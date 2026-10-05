#!/usr/bin/env bash
# E15 watchtower scenario: demonstrates the watcher detecting and answering a stale challenge
# on the fixturenet, and (in "current" mode) detecting but not answering a challenge that already
# carries the watcher's latest state.
#
# Usage: scenario.sh <stale|current>
#   stale   - the counterparty challenges with the older state N (turn 12); the watcher holds the
#              newer state N+1 (turn 13) and answers on-chain with a checkpoint.
#   current - the counterparty challenges with state N (turn 12), which is the same turn the
#              watcher holds; the watcher sees the event but sends no response.
#
# The script ends by emitting a single JSON line: {detected, responded, block, latency_ms, tx_hash}.

set -euo pipefail

MODE="${1:?usage: scenario.sh <stale|current>}"
TOWER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export WATCH_RPC="${WATCH_RPC:-http://127.0.0.1:8545}"
export MANIFEST_PATH="${MANIFEST_PATH:-$HOME/deployments/armada-fixturenet-e12/data/armada_env/manifest.json}"
export KEYS_DIR="${KEYS_DIR:-$HOME/deployments/armada-fixturenet-e12/data/armada_env}"
export OUT_DIR="${OUT_DIR:-$TOWER_DIR}"

TSX="$TOWER_DIR/node_modules/.bin/tsx"
cd "$TOWER_DIR"

# The fixturenet's test-account key files are root-owned 600 by default (only the env container,
# running as root, can read them); the operator resets the deployment (and its permissions)
# between chunks. Make them world-readable so this script -- run directly on the host -- can read
# them too. Best-effort: if this is already readable (a previous run fixed it, or the deployment
# was provisioned readable), nothing to do.
if ! [ -r "$KEYS_DIR/keys/0x70997970C51812dc3A010C7d01b50e0d17dc79C8.key" ]; then
  sudo chmod 644 "$KEYS_DIR"/keys/*.key
fi

# 1. Build + sign the demo channel's states; write held-state.json / challenge.json.
build_json="$($TSX helper.ts build "$MODE")"
channel_id="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["channelId"])' <<<"$build_json")"

# 2. Resolve the adjudicator address and the user (watcher side) key from the manifest + keys dir.
adjudicator="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["armadaNitro"]["adjudicator"])' "$MANIFEST_PATH")"
user_addr="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["testAccounts"][0]["address"])' "$MANIFEST_PATH")"
user_key="$(cat "$KEYS_DIR/keys/${user_addr}.key")"

export WATCH_CHANNEL="$channel_id"
export WATCH_STATE_FILE="$TOWER_DIR/held-state.json"
export WATCH_ADJUDICATOR="$adjudicator"
export WATCH_SIGNER_KEY="$user_key"
export WATCH_WINDOW_S="${WATCH_WINDOW_S:-60}"

# 3. Start the watcher (subscribes to ChallengeRegistered for the channel).
watcher_out="$TOWER_DIR/.watcher-out"
($TSX watch.ts) > "$watcher_out" &
watcher_pid=$!

# 4. Give the watcher time to connect and subscribe before the challenge lands (so the event is not
#    missed), then trigger the counterparty's stale challenge (the hub challenges with state N).
sleep 2
($TSX helper.ts challenge) > /dev/null

# 5. Wait for the watcher to finish and collect its JSON.
wait "$watcher_pid" || true
cat "$watcher_out"
