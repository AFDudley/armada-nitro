#!/usr/bin/env bash
# armada-assets-e2e gate, teardown check (E11 c4/c7).
#
# Runs stack/compose-jobs/armada-assets-e2e/run.sh to the end on its default
# (no KEEP_FIXTURENET) path, then verifies: no armada-assets-e2e deployment
# runs, the deployment directory is gone, the warm base-layer snapshot
# (saved by run.sh's own c3 step) is still present, and the snapshot's cache
# location does not nest inside (or contain) the deployment directory --
# removing the deployment directory can therefore never remove the snapshot.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." &>/dev/null && pwd)
# shellcheck source=stack/scripts/fixturenet-base-common.sh
source "${REPO_ROOT}/stack/scripts/fixturenet-base-common.sh"

NAME="armada-assets-e2e"
DEP="${HOME}/deployments/${NAME}"
CLUSTER_ID_FILE="${REPO_ROOT}/.scratch/armada-assets-e2e-cluster-id"

rm -f "$CLUSTER_ID_FILE"
unset KEEP_FIXTURENET
bash "${SCRIPT_DIR}/run.sh"

deployment_dir_present=false
[ -d "$DEP" ] && deployment_dir_present=true

deployment_running=false
if [ -f "$CLUSTER_ID_FILE" ]; then
  cluster=$(cat "$CLUSTER_ID_FILE")
  ctr="${cluster}-armada-fixturenet-geth-1"
  if docker ps -a --filter "name=^${ctr}$" --format '{{.Names}}' | grep -q .; then
    deployment_running=true
  fi
fi

KEY=$(compute_base_key "$REPO_ROOT")
SNAP=$(snap_path "$KEY")
snapshot_present_after_exit=false
[ -f "$SNAP" ] && snapshot_present_after_exit=true

# Neither path is a prefix of the other: the snapshot cache (SNAP_DIR, from
# fixturenet-base-common.sh) and the deployment directory are siblings under
# ~/deployments, never nested one inside the other.
snapshot_outside_deployment_dir=false
case "$SNAP" in
  "${DEP}"/*) snapshot_outside_deployment_dir=false ;;
  *)
    case "$DEP" in
      "${SNAP_DIR}"/*) snapshot_outside_deployment_dir=false ;;
      *) snapshot_outside_deployment_dir=true ;;
    esac
    ;;
esac

printf '{"deployment_running":%s,"deployment_dir_present":%s,"snapshot_present_after_exit":%s,"snapshot_outside_deployment_dir":%s}\n' \
  "$deployment_running" "$deployment_dir_present" "$snapshot_present_after_exit" "$snapshot_outside_deployment_dir"
