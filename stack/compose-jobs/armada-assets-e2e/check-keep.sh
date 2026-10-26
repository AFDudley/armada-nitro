#!/usr/bin/env bash
# armada-assets-e2e gate, keep check (E11 c6).
#
# Runs stack/compose-jobs/armada-assets-e2e/run.sh with KEEP_FIXTURENET=1,
# verifies the fixturenet is still running after the gate exits (its exit
# trap must skip teardown under KEEP_FIXTURENET=1), then this check itself
# tears the kept fixturenet down -- so a KEEP_FIXTURENET=1 run never leaks a
# running deployment past this check.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." &>/dev/null && pwd)

NAME="armada-assets-e2e"
DEP="${HOME}/deployments/${NAME}"
SPEC="${DEP}-spec.yml"
CLUSTER_ID_FILE="${REPO_ROOT}/.scratch/armada-assets-e2e-cluster-id"

rm -f "$CLUSTER_ID_FILE"
KEEP_FIXTURENET=1 bash "${SCRIPT_DIR}/run.sh"

fixturenet_running_after_exit=false
if [ -f "$CLUSTER_ID_FILE" ]; then
  cluster=$(cat "$CLUSTER_ID_FILE")
  ctr="${cluster}-armada-fixturenet-geth-1"
  if docker ps --filter "name=^${ctr}$" --format '{{.Names}}' | grep -q .; then
    fixturenet_running_after_exit=true
  fi
fi

printf '{"fixturenet_running_after_exit":%s}\n' "$fixturenet_running_after_exit"

# The check then removes the kept fixturenet (never left running past here).
LACONIC="${LACONIC_SO:-$(command -v laconic-so || true)}"
if [ -n "$LACONIC" ] && [ -e "${DEP}/spec.yml" ]; then
  "$LACONIC" deployment --dir "$DEP" stop --delete-volumes >/dev/null 2>&1 || true
fi
if [ -d "${DEP}/data" ]; then
  sudo umount "${DEP}/data" 2>/dev/null || true
fi
rm -rf "$DEP" "$SPEC"
