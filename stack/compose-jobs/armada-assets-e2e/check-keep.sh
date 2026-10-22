#!/usr/bin/env bash
# check-keep.sh (c6).
#
# Runs run.sh with KEEP_FIXTURENET=1 (so its exit trap skips teardown), then
# verifies the fixturenet is still running after run.sh has exited, then
# removes it itself.
#
# Prints one JSON line: {"fixturenet_running_after_exit": <bool>}.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
DEP_NAME="${ARMADA_ASSETS_DEP_NAME:-armada-assets-e2e}"
DEP="${HOME}/deployments/${DEP_NAME}"
LACONIC="${LACONIC_SO:-$(command -v laconic-so || true)}"

KEEP_FIXTURENET=1 bash "${SCRIPT_DIR}/run.sh" >/dev/null

# c6: the fixturenet must still be running after run.sh has exited.
fixturenet_running_after_exit=false
if [ -d "$DEP" ]; then
  cluster=$(awk '/^cluster-id:/{print $2}' "${DEP}/deployment.yml" 2>/dev/null || true)
  if [ -n "$cluster" ] && docker ps --format '{{.Names}}' | grep -q "^${cluster}-"; then
    fixturenet_running_after_exit=true
  fi
fi

printf '{"fixturenet_running_after_exit": %s}\n' "$fixturenet_running_after_exit"

# The check then removes the fixturenet it kept.
if [ -n "$LACONIC" ] && [ -d "$DEP" ]; then
  "$LACONIC" deployment --dir "$DEP" stop >/dev/null 2>&1 || true
  if [ -d "${DEP}/data" ]; then
    sudo umount "${DEP}/data" 2>/dev/null || true
  fi
  rm -rf "$DEP"
fi
