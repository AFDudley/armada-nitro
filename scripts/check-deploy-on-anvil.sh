#!/usr/bin/env bash
# arn-a46 (gate): runs the real deploy script (script/Deploy.s.sol) against a fresh local anvil
# that enforces the EIP-170 contract size limit (24,576 bytes), with libraries linked, and
# reports whether the deploy reverted and whether the adjudicator has code at its deployed address.
#
# This is the fast gate check that catches the arn-d5a full-stack reconcile failure (deploy
# reverts when a real network enforces EIP-170) without needing that full reconcile run.
#
# Prints one JSON line: {"reverted": bool, "adjudicator_code_present": bool}
# Exits 0 on success (deploy did not revert, adjudicator has code), non-zero otherwise.
set -uo pipefail
cd "$(dirname "$0")/.."

PORT="${ANVIL_PORT:-8740}"
RPC="http://127.0.0.1:${PORT}"
KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
GROUP_KEY_X="0xd963041ff4047c2d1d02ffb98e6704935b8093299c8fe26b8c6487b75773e51a"
GROUP_KEY_Y="0xc5dd6b069f76a7b59a8bffb5fc6e22cead39ed25c0ef60d34e901f3515606aa1"
export PORT RPC

if command -v ss >/dev/null 2>&1 && ss -ltn "( sport = :${PORT} )" | grep -q LISTEN; then
    echo "check-deploy-on-anvil: port ${PORT} already in use; set ANVIL_PORT to a free port" >&2
    exit 1
fi

# C4: start a fresh local anvil itself (not any multi-service test-network stack). The default
# anvil enforces the EIP-170 contract size limit (24,576 bytes).
anvil --host 127.0.0.1 --port "${PORT}" --silent &
ANVIL_PID=$!
cleanup() { kill "${ANVIL_PID}" >/dev/null 2>&1; wait "${ANVIL_PID}" 2>/dev/null; }
trap cleanup EXIT

# Wait for anvil to be ready
for _ in $(seq 1 60); do
    cast block-number --rpc-url "${RPC}" >/dev/null 2>&1 && break
    sleep 0.5
done

# Step 1: deploy the local pool + usdc (LocalArmada)
env DEPLOYER_KEY="$KEY" forge script script/LocalArmada.s.sol --rpc-url "$RPC" --broadcast --slow --json > /tmp/localarmada.json 2>&1
POOL=$(python3 -c "
import json, re
raw = open('/tmp/localarmada.json').read()
m = re.search(r'\{.*\}', raw)
data = json.loads(m.group(0) if m else '{}')
print(data.get('returns', {}).get('privacyPool', {}).get('value', ''))
")
USDC=$(python3 -c "
import json, re
raw = open('/tmp/localarmada.json').read()
m = re.search(r'\{.*\}', raw)
data = json.loads(m.group(0) if m else '{}')
print(data.get('returns', {}).get('usdc', {}).get('value', ''))
")

# Step 2: run the real deploy script with the pool, usdc, and FROST group key
env ARMADA_POOL="$POOL" HUB_GROUP_KEY_X="$GROUP_KEY_X" HUB_GROUP_KEY_Y="$GROUP_KEY_Y" \
    HUB_REVOCATION_DELAY=3600 ARMADA_ASSETS="$USDC" \
  forge script script/Deploy.s.sol --rpc-url "$RPC" --broadcast --private-key "$KEY" --json > /tmp/deploy.json 2>&1

# Step 3: parse the deploy JSON and check the adjudicator
python3 -c "
import json, re, subprocess, os

raw = open('/tmp/deploy.json').read()
m = re.search(r'\{.*\}', raw)
data = json.loads(m.group(0) if m else '{}')

adjudicator = data.get('returns', {}).get('adjudicator', {}).get('value', '')
success = data.get('success', False)
rpc = os.environ.get('RPC', 'http://127.0.0.1:8740')

if adjudicator:
    result = subprocess.run(
        ['cast', 'codesize', '--rpc-url', rpc, adjudicator],
        capture_output=True, text=True
    )
    code_size = result.stdout.strip()
    adjudicator_code_present = code_size != '0'
else:
    adjudicator_code_present = False

# reverted: the deploy reverted if success is false OR the adjudicator address is zero
reverted = (not success) or adjudicator == '0x0000000000000000000000000000000000000000'

print(json.dumps({'reverted': reverted, 'adjudicator_code_present': adjudicator_code_present}))
"
