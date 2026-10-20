#!/usr/bin/env bash
# armada-assets-e2e gate job (arn-a18).
#
# Stands up a fresh assets fixturenet (Aave pool, waUSDC, USDC and the
# adjudicator) via stack/scripts/fixturenet-new under a run-unique name with
# TMPDIR set to the repo .scratch, verifies the Aave pool, waUSDC and USDC
# answer on the fixturenet RPC, confirms a base-layer snapshot exists for a
# later warm run, then prints one JSON line.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." && pwd)
JOB_DIR="${REPO_ROOT}/stack/compose-jobs/armada-assets-e2e"

# --- c1: the job's own files are present. ---------------------------------
job_files_present=true
for f in run.sh docker-compose-armada-assets-e2e.yml assets-rpc-check.sh; do
  if [ ! -f "${JOB_DIR}/${f}" ]; then
    job_files_present=false
  fi
done

# --- c3: stand up a fresh fixturenet via fixturenet-new (unique name + TMPDIR).
NAME="assets-$(date +%s)-$$"
DEP="${HOME}/deployments/${NAME}"
mkdir -p "${REPO_ROOT}/.scratch"
export TMPDIR="${REPO_ROOT}/.scratch"
echo "armada-assets-e2e: standing up fixturenet ${NAME} ..."
bash "${REPO_ROOT}/stack/scripts/fixturenet-new" "${NAME}"

# --- c3: the Aave pool, waUSDC and USDC answer on the fixturenet RPC.
fixturenet_up=$(bash "${JOB_DIR}/assets-rpc-check.sh" "${DEP}")

# --- c4: a base-layer snapshot exists for a later warm run. fixturenet-new's cold
# path writes exactly one armada-fixturenet-base-<key>.tar.zst (pruning every other
# one -- stack/scripts/fixturenet-base-snapshot keeps exactly one); checking for its
# presence this way (rather than recomputing the key here) is immune to the key
# shifting between this process's start and now from a concurrent cold build's image
# layers landing in the shared docker image cache.
shopt -s nullglob
snaps=("${HOME}/deployments/.snapshots"/armada-fixturenet-base-*.tar.zst)
shopt -u nullglob
if [ "${#snaps[@]}" -gt 0 ]; then
  snapshot_present=true
else
  snapshot_present=false
fi

# --- the single summary line.
echo "{\"job_files_present\": ${job_files_present}, \"fixturenet_up\": ${fixturenet_up}, \"snapshot_present\": ${snapshot_present}}"
