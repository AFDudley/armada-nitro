#!/usr/bin/env bash
# verify-fixturenet-new-missing-base.sh <name>
#
# Oracle for arn-46d.1: with the base snapshot for the current base-key.py key
# DELETED, prove that stack/scripts/fixturenet-new:
#   c1 -- exits non-zero (refuses to build the base layer inline)
#   c2 -- prints the current key and the build command stack/scripts/fixturenet-base-build
#   c3 -- starts no base build and creates no base snapshot
#   c4 -- the text "run_reconcile base" is absent from fixturenet-new
#
# The script runs fixturenet-new once, captures its exit code + output, and emits
# a JSON object with these fields:
#   fixturenet_new_exit_code, output_has_key, output_has_build_command,
#   base_build_started, base_snapshot_created
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
NAME="${1:-verify-net}"

# Current base key: the sha256 prefix of base-key.py's canonical lines (the exact
# inputs fixturenet-new uses).
KEY=$(python3 "${REPO_ROOT}/stack/scripts/base-key.py" --root "$REPO_ROOT" | sha256sum | cut -c1-16)
if [ -z "${KEY}" ]; then
  echo "verify-fixturenet-new-missing-base.sh: could not compute the current base key" >&2
  exit 1
fi

# Establish the COLD state: point FIXTURENET_SNAP_DIR at a fresh, empty
# throwaway directory under the repo's own .scratch/, so fixturenet-new (run
# below) and this script's own snapshot check both see "no snapshot for this
# key" without ever reading or deleting the operator's real
# ${HOME}/deployments/.snapshots. A fresh mktemp dir starts empty -- nothing
# to remove.
export FIXTURENET_SNAP_DIR
FIXTURENET_SNAP_DIR=$(mktemp -d "${REPO_ROOT}/.scratch/verify-fixturenet-new-missing-base.XXXXXX")
trap 'rm -rf "${FIXTURENET_SNAP_DIR}"' EXIT
SNAP_DIR="${FIXTURENET_SNAP_DIR}"

# Run fixturenet-new, capture full output + exit code.
OUT=$(bash "${SCRIPT_DIR}/fixturenet-new" "$NAME" 2>&1)
EC=$?

# c2: does the output contain the key and the build command?
output_has_key=false
if printf '%s' "$OUT" | grep -qF -- "${KEY}"; then output_has_key=true; fi
output_has_build_command=false
if printf '%s' "$OUT" | grep -qF -- "stack/scripts/fixturenet-base-build"; then output_has_build_command=true; fi

# c3: did a base build start? marker "base reconcile" only appears when
# run_reconcile base ran. It is absent in the cold early-exit path.
base_build_started=false
if printf '%s' "$OUT" | grep -qF -- "base reconcile"; then base_build_started=true; fi

# c3: was a base snapshot created? check for the snapshot file for this key.
base_snapshot_created=false
if [ -f "${SNAP_DIR}/armada-fixturenet-base-${KEY}.tar.zst" ]; then base_snapshot_created=true; fi

# Emit the result as JSON on stdout.
printf '{"fixturenet_new_exit_code": %s, "output_has_key": %s, "output_has_build_command": %s, "base_build_started": %s, "base_snapshot_created": %s}\n' \
  "$EC" "$output_has_key" "$output_has_build_command" "$base_build_started" "$base_snapshot_created"
