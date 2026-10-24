#!/usr/bin/env bash
# armada-assets-e2e gate, stand-up (E11).
#
# Stands up a fresh Aave fixturenet (warm restore of the base-layer snapshot,
# stack/scripts/fixturenet-base-common.sh's restore_snapshot), verifies the Aave
# lending pool, waUSDC and USDC answer on the fixturenet RPC (the base
# target's --verify-only reconcile pass -- env/reconciler/modules/aave.py,
# usdc.py -- sends no transactions), saves a warm base-layer snapshot for a
# later chunk (stack/scripts/fixturenet-base-snapshot), and tears down the
# running fixturenet + removes the deployment directory on exit via a trap
# (c5), unless KEEP_FIXTURENET=1 (c6).
#
# A later chunk's deposit/channel/payout scenario reuses this environment's
# wallet + proof code from env/gates/nitro-e2e/prepare.ts (the Railgun wallet
# creation in lib/sdk/wallet and the Groth16 unshield proof in lib/sdk/prover
# that prepare.ts drives). This stand-up-only gate does not shield, deposit,
# open a channel or build a proof itself -- no deposit/channel/payout/reclaim
# is in scope here -- but names prepare.ts as the wallet/proof code the later
# chunk that consumes this gate's snapshot will reuse.
#
# Only the BASE target (weth, usdc, cctp, aave, lido, armada -- the six
# modules stack/scripts/fixturenet-base-common.sh's BASE_MODULES names) is
# reconciled: the snapshot cache holds the base layer only, and
# fixturenet-base-snapshot refuses to snapshot a deployment whose manifest
# names anything else (require_base_only_manifest). armada_nitro + funding
# (the full target's remaining two modules) are out of scope for this gate.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." &>/dev/null && pwd)
# shellcheck source=stack/scripts/fixturenet-base-common.sh
source "${REPO_ROOT}/stack/scripts/fixturenet-base-common.sh"

NAME="armada-assets-e2e"
DEP="${HOME}/deployments/${NAME}"
SPEC="${DEP}-spec.yml"
STACK="stack/stacks/armada-nitro-fixturenet"
CONFIG="stack/config/deployment-config.example.env"
BASE_TARGET_IN_CONTAINER="/src/armada-nitro/env/targets/fixturenet-base.json"
CLUSTER_ID_FILE="${REPO_ROOT}/.scratch/armada-assets-e2e-cluster-id"

now() { date +%s; }

# ---- c1: the gate's own job files all exist -------------------------------
job_files_present=true
for f in run.sh check-teardown.sh check-keep.sh; do
  if [ ! -f "${SCRIPT_DIR}/${f}" ]; then
    echo "run.sh: missing job file ${f}" >&2
    job_files_present=false
  fi
done

# ---- c5/c6: exit trap tears down the running fixturenet + removes the ------
# deployment directory, unless KEEP_FIXTURENET=1 keeps it running for a later
# chunk's inspection. The warm snapshot cache (~/deployments/.snapshots, c7)
# is never touched here -- only the deployment directory is removed.
teardown() {
  if [ "${KEEP_FIXTURENET:-}" = "1" ]; then
    echo "run.sh: KEEP_FIXTURENET=1 -- leaving the fixturenet running at ${DEP}"
    return 0
  fi
  echo "run.sh: tearing down the running fixturenet ..."
  if [ -e "${DEP}/spec.yml" ]; then
    "$LACONIC" deployment --dir "$DEP" stop --delete-volumes >/dev/null 2>&1 || true
  fi
  if [ -d "${DEP}/data" ]; then
    sudo umount "${DEP}/data" 2>/dev/null || true
  fi
  rm -rf "$DEP" "$SPEC"
  echo "run.sh: ${DEP} removed"
}
trap teardown EXIT

# ---- resolve laconic-so (mirrors stack/scripts/fixturenet-new) -------------
LACONIC="${LACONIC_SO:-$(command -v laconic-so || true)}"
if [ -z "$LACONIC" ]; then
  echo "run.sh: laconic-so not found on PATH; set LACONIC_SO or add it to PATH" >&2
  exit 1
fi

export ARMADA_IMAGE_TAG
ARMADA_IMAGE_TAG=$(git -C "$REPO_ROOT" rev-parse HEAD)
export CERC_CONTAINER_BASE_DIR="${CERC_CONTAINER_BASE_DIR:-${HOME}/src/stack-orchestrator/stack_orchestrator/data/container-build}"
for kind in env foundry; do
  if ! docker image inspect "cerc/armada-nitro-${kind}:${ARMADA_IMAGE_TAG}" >/dev/null 2>&1; then
    echo "run.sh: building cerc/armada-nitro-${kind}:${ARMADA_IMAGE_TAG} ..."
    bash "${REPO_ROOT}/stack/container-build/cerc-armada-nitro-${kind}/build.sh" >/dev/null
  fi
done

# ---- c2: stand up a fresh Aave fixturenet (warm restore only -- this gate --
# never builds the base layer itself, mirroring fixturenet-new's rule) -------
KEY=$(compute_base_key "$REPO_ROOT")
SNAP=$(snap_path "$KEY")
if [ ! -f "$SNAP" ]; then
  echo "run.sh: COLD: no base snapshot for key=${KEY} (${SNAP})" >&2
  echo "  this gate never builds the base layer itself (arn-46d.1) -- the operator" >&2
  echo "  base-layer build script builds it first" >&2
  exit 1
fi

if [ ! -e "$DEP" ]; then
  echo "run.sh: deploy init + create ${DEP}"
  "$LACONIC" --stack "$STACK" deploy init \
    --map-ports-to-host localhost-fixed-random \
    --config-file "${REPO_ROOT}/${CONFIG}" \
    --output "$SPEC"
  "$LACONIC" --stack "$STACK" deploy create \
    --spec-file "$SPEC" --deployment-dir "$DEP"
else
  echo "run.sh: ${DEP} exists -- resuming (skipping init/create)"
fi

mkdir -p "$(dirname "$CLUSTER_ID_FILE")"
awk '/^cluster-id:/{print $2}' "${DEP}/deployment.yml" > "$CLUSTER_ID_FILE"

DATA_SIZE="${FIXTURENET_DATA_SIZE:-3G}"
data_fs() { stat -f -c %T "${DEP}/data"; }
if [ "$(data_fs)" != tmpfs ]; then
  if sudo find "${DEP}/data" -mindepth 1 -not -type d -print -quit | grep -q .; then
    echo "run.sh: ${DEP}/data on disk holds files -- refusing to mount the RAM disk over them" >&2
    exit 1
  fi
  sudo find "${DEP}/data" -mindepth 1 -depth -type d -empty -delete
  sudo mount -t tmpfs -o "size=${DATA_SIZE},mode=0700" tmpfs "${DEP}/data"
fi

KEYFILE=$(key_path "$KEY")
if ! check_restore_key_diff "$REPO_ROOT" "$KEYFILE"; then
  echo "run.sh: restore REFUSED: recorded key lines differ from the fresh base-key.py output" >&2
  exit 1
fi
echo "run.sh: restoring ${SNAP} into ${DEP}/data ..."
restore_snapshot "$DEP" "$SNAP"
"$LACONIC" deployment --dir "$DEP" start

RPC=
resolve_geth_rpc() {
  local cluster ctr line
  cluster=$(cat "$CLUSTER_ID_FILE")
  ctr="${cluster}-armada-fixturenet-geth-1"
  line=$(docker port "${ctr}" 8545 2>/dev/null || true)
  if [ -z "${line}" ]; then
    echo "run.sh: FAILED: no published 8545 for ${ctr}" >&2
    return 1
  fi
  RPC="http://$(echo "${line#*->}" | tr -d "[:space:]")"
  echo "run.sh: geth RPC = ${RPC} (docker port)"
}
wait_for_blocks() {
  local deadline=$(( $(now) + 180 )) b0="" b1
  resolve_geth_rpc || return 1
  while [ "$(now)" -lt "$deadline" ]; do
    b1=$(curl -s --max-time 3 -H 'Content-Type: application/json' \
           --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
           "$RPC" 2>/dev/null | jq -r '.result // empty' 2>/dev/null || true)
    if [ -n "$b1" ]; then
      if [ -z "$b0" ]; then b0="$b1"
      elif [ "$b1" != "$b0" ]; then
        echo "run.sh: blocks advancing ($((b0)) -> $((b1)))"
        return 0
      fi
    fi
    sleep 2
  done
  echo "run.sh: FAILED: no new block within 180s (last=${b1:-none})" >&2
  return 1
}
wait_for_blocks

# ---- verify the base target (Aave pool, waUSDC, USDC + the rest of the -----
# base modules) against the restored chain, read-only (--verify-only sends no
# transactions). env/reconciler/modules/aave.py's verify reads
# getReserveData(usdc) off the pool and asset() off waUSDC;
# env/reconciler/modules/usdc.py's verify reads name()/symbol()/decimals() off
# the USDC proxy -- all three answering is exactly "the Aave lending pool,
# waUSDC and USDC answer on the fixturenet RPC". `set -o pipefail` (above)
# makes a reconciler verify failure (reconciler: FAILED: ..., exit 1) kill
# this script, so reaching the next line already proves the verify passed.
mkdir -p "${REPO_ROOT}/.scratch"
VERIFY_LOG="${REPO_ROOT}/.scratch/armada-assets-e2e-verify.log"
RECONCILER_TARGET="$BASE_TARGET_IN_CONTAINER" RECONCILER_VERIFY_ONLY=1 \
  "$LACONIC" deployment --dir "$DEP" run-job armada-env-reconcile 2>&1 | tee "$VERIFY_LOG"
echo "run.sh: base-target verify module results:"
grep -E '^(weth|usdc|cctp|aave|lido|armada), ' "$VERIFY_LOG" | sed 's/^/    /' || true
fixturenet_up=true
echo "run.sh: fixturenet_up -- Aave pool, waUSDC and USDC all answered the base-target verify"

# ---- c3: save a warm base-layer snapshot for a later chunk -----------------
echo "run.sh: saving the warm base-layer snapshot ..."
bash "${REPO_ROOT}/stack/scripts/fixturenet-base-snapshot" "$DEP"
snapshot_present=false
[ -f "$(snap_path "$(compute_base_key "$REPO_ROOT")")" ] && snapshot_present=true

printf '{"job_files_present":%s,"fixturenet_up":%s,"snapshot_present":%s}\n' \
  "$job_files_present" "$fixturenet_up" "$snapshot_present"
