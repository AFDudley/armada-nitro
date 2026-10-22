#!/usr/bin/env bash
# armada-assets-e2e gate (E11 stand-up).
#
# Stands up a fresh Aave fixturenet via stack/scripts/fixturenet-new (warm
# path when a base-layer snapshot exists for the current inputs, cold path
# otherwise). Runs the armada-assets-e2e compose job, which reuses the wallet
# and proof code of env/gates/nitro-e2e/prepare.ts and proves the Aave lending
# pool, waUSDC and USDC answer on the fixturenet RPC -- entirely from inside
# the job, over the compose network (never a host-side read of the
# deployment's root-owned data directory). Saves the warm snapshot for a
# later chunk, and on exit tears down the running fixturenet and removes its
# deployment directory. The running fixturenet is kept only under
# KEEP_FIXTURENET=1. The warm snapshot cache is not the deployment directory,
# so removing the deployment directory leaves the snapshot for reuse.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." &>/dev/null && pwd)

DEP_NAME="${ARMADA_ASSETS_DEP_NAME:-armada-assets-e2e}"
DEP="${HOME}/deployments/${DEP_NAME}"
# c8: the job reuses the wallet and proof code of prepare.ts.
PREPARE_TS="${REPO_ROOT}/env/gates/nitro-e2e/prepare.ts"
LACONIC="${LACONIC_SO:-$(command -v laconic-so || true)}"
[ -n "$LACONIC" ] || { echo "armada-assets-e2e: laconic-so not found; set LACONIC_SO or add it to PATH" >&2; exit 1; }

# c1: all of the job's files exist.
JOB_FILES=("${SCRIPT_DIR}/run.sh" "${SCRIPT_DIR}/check-teardown.sh" "${SCRIPT_DIR}/check-keep.sh" "${REPO_ROOT}/stack/compose-jobs/docker-compose-${DEP_NAME}.yml" "${PREPARE_TS}")
job_files_present=true
for f in "${JOB_FILES[@]}"; do
  if [ ! -e "$f" ]; then
    job_files_present=false
    echo "armada-assets-e2e: missing job file: $f" >&2
  fi
done

# c5/c6: exit trap tears down the running fixturenet; KEEP_FIXTURENET=1 keeps it.
teardown() {
  if [ "${KEEP_FIXTURENET:-0}" = "1" ]; then
    echo "armada-assets-e2e: KEEP_FIXTURENET=1 — keeping the running fixturenet"
  else
    if [ -d "$DEP" ]; then
      echo "armada-assets-e2e: tearing down ${DEP_NAME}"
      "$LACONIC" deployment --dir "$DEP" stop >/dev/null 2>&1 || true
      if [ -d "${DEP}/data" ]; then
        sudo umount "${DEP}/data" 2>/dev/null || true
      fi
      rm -rf "$DEP"
    fi
  fi
}
trap 'teardown' EXIT

# Stand up the Aave fixturenet (warm if a base-layer snapshot exists for the
# current inputs, cold + snapshot otherwise).
bash "${REPO_ROOT}/stack/scripts/fixturenet-new" "${DEP_NAME}"

# Run the armada-assets-e2e compose job: reuses prepare.ts's wallet and proof
# code, and proves the Aave pool/waUSDC/USDC answer entirely from inside the
# job (its stdout carries a {"fixturenet_up": <bool>} line, c2). Non-fatal:
# the job_files_present and snapshot_present fields below do not depend on it.
JOB_OUTPUT=$("$LACONIC" deployment --dir "$DEP" run-job "${DEP_NAME}" 2>&1) || true
echo "$JOB_OUTPUT" >&2

# c2: the Aave lending pool, waUSDC and USDC answer on the fixturenet RPC
# (reported by the job's own JSON line, the last line that parses as JSON).
fixturenet_up=false
job_json=$(printf '%s\n' "$JOB_OUTPUT" | grep -E '^\{.*\}$' | tail -1 || true)
if [ -n "$job_json" ] && printf '%s' "$job_json" | jq -e '.fixturenet_up == true' >/dev/null 2>&1; then
  fixturenet_up=true
fi

# c3: the warm snapshot is saved (the cold path creates it, the warm path restores it).
snapshot_present=false
if ls "${HOME}/deployments/.snapshots/"armada-fixturenet-base-*.tar.zst >/dev/null 2>&1; then
  snapshot_present=true
fi

# Summary JSON line.
printf '{"job_files_present": %s, "fixturenet_up": %s, "snapshot_present": %s}\n' \
  "$job_files_present" "$fixturenet_up" "$snapshot_present"
