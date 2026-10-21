#!/usr/bin/env bash
# run.sh — the armada-assets-e2e gate job orchestrator (arn-a18).
#
# Stands up a fresh fixturenet with stack/scripts/fixturenet-new under a run-unique
# name (TMPDIR set to the repo .scratch), which builds and snapshots the base layer
# so a later run is warm. Brings the fixturenet to ready with the Aave pool, waUSDC,
# USDC and the adjudicator deployed by running the armada-assets-e2e compose job via
# laconic-so run-job (never a direct host read of the deployment's own data directory).
# The job's own scripts (stack/compose-jobs/armada-assets-e2e/armada-assets-e2e-job.py)
# reuse the wallet + proof code in env/gates/nitro-e2e/prepare.ts, then prove the
# fixturenet is ready (Aave pool, waUSDC and USDC respond on the fixturenet RPC).
#
# Prints exactly one JSON line to stdout (all diagnostics go to stderr):
#   {"job_files_present": true, "fixturenet_up": true, "snapshot_present": true}
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." &>/dev/null && pwd)
JOB_DIR="${REPO_ROOT}/stack/compose-jobs/armada-assets-e2e"

# c3/c4: TMPDIR is set to the repo .scratch -- the acceptance stands up a fresh
# fixturenet with stack/scripts/fixturenet-new under a run-unique name, which builds
# and snapshots the base layer so a later run is warm.
TMPDIR="${REPO_ROOT}/.scratch"
mkdir -p "$TMPDIR"
export TMPDIR

# run-unique name per run: each invocation creates a fresh fixturenet deployment dir.
NAME="armada-assets-e2e-$(date +%s)-${RANDOM}"
DEP="${HOME}/deployments/${NAME}"

# Jobs name their image as cerc/armada-nitro-env:${ARMADA_IMAGE_TAG} (arn-895): the
# image built from this checkout's committed content, tagged with HEAD's sha.
ARMADA_IMAGE_TAG=$(git -C "$REPO_ROOT" rev-parse HEAD)
export ARMADA_IMAGE_TAG

# Resolve laconic-so from LACONIC_SO, else the PATH copy.
LACONIC="${LACONIC_SO:-$(command -v laconic-so || true)}"
if [ -z "$LACONIC" ]; then
  echo "run.sh: laconic-so not found; set LACONIC_SO or add it to PATH" >&2
  exit 1
fi

# c3: stand up the fresh fixturenet. The cold path builds + snapshots the base layer;
# the warm path restores it.
echo "run.sh: standing up fresh fixturenet ${NAME} (TMPDIR=${TMPDIR}, image tag=${ARMADA_IMAGE_TAG})" >&2
TMPDIR="$TMPDIR" ARMADA_IMAGE_TAG="$ARMADA_IMAGE_TAG" \
  bash "${REPO_ROOT}/stack/scripts/fixturenet-new" "$NAME"

# c3: bring the fixturenet to ready by running the armada-assets-e2e job (the job's
# scripts reuse the wallet + proof code in env/gates/nitro-e2e/prepare.ts, then prove
# the Aave pool, waUSDC and USDC respond on the fixturenet RPC).
echo "run.sh: running the armada-assets-e2e job (run-job)" >&2
JOB_OUT="$(TMPDIR="$TMPDIR" ARMADA_IMAGE_TAG="$ARMADA_IMAGE_TAG" \
  "$LACONIC" deployment --dir "$DEP" run-job armada-assets-e2e || true)"

# Parse fixturenet_up from the job's one-line JSON (the job prints {"fixturenet_up": ...}).
FIXTURENET_UP=$(printf '%s\n' "$JOB_OUT" | python3 -c '
import sys, json
up = False
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        parsed = json.loads(line)
        if isinstance(parsed, dict) and "fixturenet_up" in parsed:
            up = bool(parsed["fixturenet_up"])
    except json.JSONDecodeError:
        continue
print("true" if up else "false")
'
)
echo "run.sh: fixturenet_up=${FIXTURENET_UP}" >&2

# c1: the job's own scripts + compose job exist under stack/compose-jobs/.
COMPOSE_JOB="${REPO_ROOT}/stack/compose-jobs/docker-compose-armada-assets-e2e.yml"
JOB_SCRIPT="${JOB_DIR}/armada-assets-e2e-job.py"
JOB_FILES_PRESENT=false
if [ -f "$COMPOSE_JOB" ] && [ -f "$JOB_SCRIPT" ]; then
  JOB_FILES_PRESENT=true
fi
echo "run.sh: job_files_present=${JOB_FILES_PRESENT} (compose job + job scripts under stack/compose-jobs/)" >&2

# c4: a base-layer snapshot exists for a later warm run (the cold path of fixturenet-new
# built and snapshotted the base layer).
SNAP_DIR="${HOME}/deployments/.snapshots"
SNAPSHOT_PRESENT=false
if ls "$SNAP_DIR"/armada-fixturenet-base-*.tar.zst >/dev/null 2>&1; then
  SNAPSHOT_PRESENT=true
fi
echo "run.sh: snapshot_present=${SNAPSHOT_PRESENT} (base-layer snapshot under ${SNAP_DIR})" >&2

# c1/c3/c4: print exactly one JSON line to stdout.
printf '{"job_files_present": %s, "fixturenet_up": %s, "snapshot_present": %s}\n' \
  "$JOB_FILES_PRESENT" "$FIXTURENET_UP" "$SNAPSHOT_PRESENT"
