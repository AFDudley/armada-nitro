#!/usr/bin/env bash
# armada-assets-e2e gate, teardown (E11, arn-5fb).
#
# Stops the armada-assets-e2e deployment and removes its directory, mirroring
# run.sh's own teardown trap and check-keep.sh's post-check cleanup. This
# script lives beside run.sh (stack/compose-jobs/, not scripts/) because it
# needs the host access the gate-no-host-deployment-access pre-commit hook
# forbids under scripts/, env/gates/ and stack/scripts/. The gate script,
# scripts/armada-assets-e2e.py, calls this helper at exit instead of touching
# the deployment's data directory itself.
#
# Honors KEEP_FIXTURENET=1 the same way run.sh does: leaves the deployment
# running and does nothing.
set -uo pipefail

NAME="armada-assets-e2e"
DEP="${HOME}/deployments/${NAME}"
SPEC="${DEP}-spec.yml"

if [ "${KEEP_FIXTURENET:-}" = "1" ]; then
  echo "teardown.sh: KEEP_FIXTURENET=1 -- leaving the fixturenet running at ${DEP}"
  exit 0
fi

echo "teardown.sh: tearing down the running fixturenet ..."
LACONIC="${LACONIC_SO:-$(command -v laconic-so || true)}"
if [ -n "$LACONIC" ] && [ -e "${DEP}/spec.yml" ]; then
  "$LACONIC" deployment --dir "$DEP" stop --delete-volumes >/dev/null 2>&1 || true
fi
if [ -d "${DEP}/data" ]; then
  sudo umount "${DEP}/data" 2>/dev/null || true
fi
# A plain rm -rf is not enough when the data dir was never a tmpfs mount
# (observed: leftover container-written files from an aborted run) --
# every file under it is root-owned, so remove it with sudo.
sudo rm -rf "$DEP" "$SPEC"
echo "teardown.sh: ${DEP} removed"
