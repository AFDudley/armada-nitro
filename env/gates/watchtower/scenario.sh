#!/bin/bash
# E15a: demonstration of the watchtower's behavior against the fixturenet.
#
# Usage: scenario.sh <stale|current>
#   stale:   the counterparty challenges with a STALE state (turn N=10); the watcher
#             (holding the newer state N+1=11) detects it and answers on-chain with a
#             checkpoint using N+1.
#   current:  the counterparty challenges with the LATEST state (turn N+1=11), which is
#             the same state the watcher holds -> the watcher detects but does NOT respond.
#
# The watcher (watch.ts) is launched first (subscribed to the ChallengeRegistered event),
# then the scenario triggers the counterparty's challenge (setup.ts). The watcher detects,
# responds (stale) or does not (current), then emits its JSON report, which this script
# relays to stdout:
#   {"detected":true,"responded":bool,"block":int,"latency_ms":int,"tx_hash":"0x..."}

set -euo pipefail

MODE="${1:-stale}"
MODE="${MODE,,}"  # lowercase
case "$MODE" in
  stale|current) ;;
  *)
    echo "usage: scenario.sh [stale|current]" >&2
    exit 1
    ;;
esac

DEP_DIR="$HOME/deployments/armada-fixturenet-e12"
MANIFEST="$DEP_DIR/data/armada_env/manifest.json"
KEYS_DIR="$DEP_DIR/data/armada_env"
RPC="http://127.0.1:8545"

# ---- read manifest values ----
ADJUDICATOR=$(python3 -c "import json,sys; m=json.load(open('$MANIFEST')); print(m['armadaNitro']['adjudicator'])")
APP=$(python3 -c "import json; m=json.load(open('$MANIFEST')); print(m['armadaNitro']['consensusApp'])")
CUSTODIAN=$(python3 -c "import json; m=json.load(open('$MANIFEST')); print(m['armadaNitro']['hubCustodian'])")
USER=$(python3 -c "import json; m=json.load(open('$MANIFEST')); print(m['testAccounts'][0]['address'])")
USER_KEYFILE=$(python3 -c "import json; m=json.load(open('$MANIFEST')); print(m['testAccounts'][0]['privateKeyFile'])")

# ---- ensure the chain is up ----
if ! curl -s -m 3 -o /dev/null -X POST "$RPC" -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"eth_blockNumber","ids":1}'; then
  echo "fixturenet chain not responding; starting via run-job" >&2
  "$HOME/bin/laconic-so" deployment --dir "$DEP_DIR" run-job armada-env-reconcile
fi

# ---- launch the watcher in the background (subscribes to ChallengeRegistered) ----
WT_OUT=$(mktemp /tmp/watchtower-report.XXXXXX)
export WT_RPC="$RPC"
export WT_MANIFEST="$MANIFEST"
export WT_KEYS="$KEYS_DIR"
export WT_USER="$USER"
export WT_CUSTODIAN="$CUSTODIAN"
export WT_APP="$APP"
export WT_NONCE="1"
export WT_CHALLENGE_DURATION="30"
export WT_DELEGATE_KEY="0x5de4111afa1a4b94908f83103eb1f170367c2e63f103b710000000"
export WT_HELD_STATE='{"turnNum":11,"isFinal":false,"userAmount":100,"hubAmount":50}'
export WT_KEY_FILE="$USER_KEYFILE"

npx -y tsx watch.ts > "$WT_OUT" &
WT_PID=$!

# ---- run the scenario: fund + trigger the counterparty's challenge ----
export ST_MODE="$MODE"
export ST_FUND_AMOUNT="100"
npx -y tsx setup.ts

# ---- wait for the watcher to detect, respond (or not), and emit its report ----
wait "$WT_PID"

# ---- relay the watcher's JSON report ----
cat "$WT_OUT"
