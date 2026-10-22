#!/usr/bin/env bash
# check-teardown.sh (c4, c7).
#
# Verifies, after a prior default run of run.sh has exited, that:
#   - no armada-assets-e2e deployment is running (c4);
#   - its deployment directory is gone (c4);
#   - the warm base-layer snapshot still exists (c4);
#   - the snapshot cache directory and the deployment directory differ and do
#     not nest (c7), so removing the deployment directory cannot touch it.
#
# Prints one JSON line: {"deployment_running": <bool>, "deployment_dir_present":
# <bool>, "snapshot_present_after_exit": <bool>, "snapshot_outside_deployment_dir": <bool>}.
set -euo pipefail

DEP_NAME="${ARMADA_ASSETS_DEP_NAME:-armada-assets-e2e}"
DEP="${HOME}/deployments/${DEP_NAME}"
SNAP_DIR="${HOME}/deployments/.snapshots"

# c4: no armada-assets-e2e deployment is running. A deployment counts as
# running iff its named geth container (or any container whose name is
# prefixed by the deployment's own cluster-id) is up; absent the deployment
# directory there is nothing to be running, and the directory check below
# already covers that case on its own.
deployment_running=false
if [ -d "$DEP" ]; then
  cluster=$(awk '/^cluster-id:/{print $2}' "${DEP}/deployment.yml" 2>/dev/null || true)
  if [ -n "$cluster" ] && docker ps --format '{{.Names}}' | grep -q "^${cluster}-"; then
    deployment_running=true
  fi
fi

# c4: the deployment directory is gone.
deployment_dir_present=false
[ -e "$DEP" ] && deployment_dir_present=true

# c4: the warm snapshot still exists.
snapshot_present_after_exit=false
if ls "${SNAP_DIR}"/armada-fixturenet-base-*.tar.zst >/dev/null 2>&1; then
  snapshot_present_after_exit=true
fi

# c7: the snapshot cache and the deployment directory differ and do not nest.
snapshot_outside_deployment_dir=false
case "${SNAP_DIR}" in
  "${DEP}"|"${DEP}"/*)
    snapshot_outside_deployment_dir=false
    ;;
  *)
    case "${DEP}" in
      "${SNAP_DIR}"|"${SNAP_DIR}"/*)
        snapshot_outside_deployment_dir=false
        ;;
      *)
        [ "${SNAP_DIR}" != "${DEP}" ] && snapshot_outside_deployment_dir=true
        ;;
    esac
    ;;
esac

printf '{"deployment_running": %s, "deployment_dir_present": %s, "snapshot_present_after_exit": %s, "snapshot_outside_deployment_dir": %s}\n' \
  "$deployment_running" "$deployment_dir_present" "$snapshot_present_after_exit" "$snapshot_outside_deployment_dir"
