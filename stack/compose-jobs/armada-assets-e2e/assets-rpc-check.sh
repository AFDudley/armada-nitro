#!/usr/bin/env bash
# usage: assets-rpc-check.sh <deployment-dir>
#
# Verify the assets fixturenet is up: the Aave pool, waUSDC and USDC answer on the
# fixturenet RPC. Reads each address from the deployment's manifest and probes the
# contract with a JSON-RPC eth_getCode on the host RPC (the geth host port is random
# per deployment, so it is discovered with `docker port`, exactly like
# stack/scripts/fixturenet-new). A non-empty "result" (more than bare "0x") proves
# the address is a deployed contract actually answering on this fixturenet's RPC.
# Echoes "true" when every contract responds, "false" otherwise, and always exits 0
# so the summary line is always printed.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <deployment-dir>" >&2
  exit 2
fi
DEP=$(cd -- "$1" && pwd) || { echo "assets-rpc-check: no such dir: $1" >&2; echo false; exit 0; }

cluster=$(awk '/^cluster-id:/{print $2}' "${DEP}/deployment.yml" 2>/dev/null || true)
line=""
if [ -n "${cluster}" ]; then
  line=$(docker port "${cluster}-armada-fixturenet-geth-1" 8545 2>/dev/null || true)
fi
if [ -z "${line}" ]; then
  echo "assets-rpc-check: geth RPC not yet published; fixturenet not up" >&2
  echo false
  exit 0
fi
RPC="http://$(echo "${line#*->}" | tr -d '[:space:]')"

MANIFEST="${DEP}/data/armada_env/manifest.json"
POOL=$(sudo jq -r '.aave.pool // empty' "${MANIFEST}" 2>/dev/null || true)
WAUSDC=$(sudo jq -r '.assets.waUSDC // empty' "${MANIFEST}" 2>/dev/null || true)
USDC=$(sudo jq -r '.usdc.proxy // empty' "${MANIFEST}" 2>/dev/null || true)
ADJ=$(sudo jq -r '.armadaNitro.adjudicator // empty' "${MANIFEST}" 2>/dev/null || true)

if [ -z "${POOL}" ] || [ -z "${WAUSDC}" ] || [ -z "${USDC}" ] || [ -z "${ADJ}" ]; then
  echo "assets-rpc-check: manifest missing aave.pool/assets.waUSDC/usdc.proxy/armadaNitro.adjudicator; fixturenet not ready" >&2
  echo false
  exit 0
fi

# A non-empty eth_getCode "result" (more than bare "0x") proves the address is a
# deployed contract that is actually answering on the fixturenet RPC.
responds() {  # responds <address>
  local addr="$1" resp code
  resp=$(curl -s --max-time 5 -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getCode\",\"params\":[\"${addr}\",\"latest\"]}" \
        "${RPC}" 2>/dev/null || true)
  code=$(printf '%s' "${resp}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result",""))' 2>/dev/null || true)
  [ -n "${code}" ] && [ "${code}" != "0x" ]
}

ok=true
for a in "${POOL}" "${WAUSDC}" "${USDC}"; do
  if ! responds "${a}"; then
    ok=false
    break
  fi
done
echo "${ok}"
