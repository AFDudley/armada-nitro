#!/usr/bin/env bash
# armada-assets-e2e gate: E11 scenario 1 (Aave yield) and scenario 4 (redeem) --
# docs/tasks/E11-aave-lido-channels.md. Runs the armada-assets-e2e laconic-so job (its own compose
# job, stack/compose-jobs/armada-assets-e2e.yml) against the operator-managed fixturenet, and
# prints the job's final JSON evidence line on stdout.
#
# Usage:
#   run.sh --scenario 1              Aave yield only
#   run.sh --scenario 1 --no-borrow  discrimination (a): the borrow is removed; the
#                                     yield-increased check must fail
#   run.sh --scenario 4              redeem only (deposits the scenario 1 principal itself if the
#                                     hub holds no waUSDC yet)
#   run.sh --all                     scenario 1 then scenario 4, in order
#
# Delegates to the shared job helper (scripts/armada_job_helper.py, arn-895), which builds the
# job's image from this checkout's committed content if it is missing, selects it, then calls
# run-job -- every job runner uses this one helper (mirrors
# scripts/run-armada-watchtower-scenario.sh).
set -euo pipefail

SCENARIO=""
NO_BORROW=""
ALL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --scenario)
      SCENARIO="${2:?--scenario needs a value (1 or 4)}"
      shift 2
      ;;
    --no-borrow)
      NO_BORROW="1"
      shift
      ;;
    --all)
      ALL="1"
      shift
      ;;
    *)
      echo "run.sh: unknown argument '$1' (use --scenario <1|4>, --no-borrow, or --all)" >&2
      exit 1
      ;;
  esac
done

if [ -n "$ALL" ]; then
  SCENARIO="all"
fi

case "$SCENARIO" in
  1|4|all) ;;
  *)
    echo "run.sh: usage: run.sh --scenario <1|4> [--no-borrow] | --all" >&2
    exit 1
    ;;
esac

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$GATE_DIR/../../.." && pwd)"
HELPER_DIR="$REPO_ROOT/scripts"

# The operator-managed fixturenet deployment (E12). Never stopped/reset/recreated here.
DEP_DIR="${DEP_DIR:-$HOME/deployments/armada-fixturenet-e12}"

PYTHON="/usr/bin/python3.12"
if [ ! -e "$PYTHON" ]; then
  PYTHON="$(command -v python3.12 || echo python3)"
fi

# The shared helper builds/selects the job's HEAD-sha image, then calls run-job itself
# (inheriting ASSETS_E2E_SCENARIO/ASSETS_E2E_NO_BORROW from this script's own environment); its
# stdout is the job's raw stdout (orchestrator chatter, the evidence lines, and the job's final
# JSON line).
output="$(ARMADA_IMAGE_DEP_DIR="$DEP_DIR" \
  ASSETS_E2E_SCENARIO="$SCENARIO" \
  ASSETS_E2E_NO_BORROW="$NO_BORROW" \
  "$PYTHON" "$HELPER_DIR/armada_job_helper.py" armada-assets-e2e)"

# The job's JSON object can land on the same physical line as preceding chatter, so scan for the
# rightmost `{...}` that parses as JSON rather than matching whole lines (mirrors
# scripts/run-armada-watchtower-scenario.sh).
json_line="$(printf '%s' "$output" | "$PYTHON" -c '
import json, sys
data = sys.stdin.read()
dec = json.JSONDecoder()
idx = data.rfind("{")
while idx != -1:
    try:
        obj, _ = dec.raw_decode(data, idx)
    except ValueError:
        idx = data.rfind("{", 0, idx)
        continue
    print(json.dumps(obj))
    sys.exit(0)
sys.exit(1)
')" || json_line=""

if [ -z "$json_line" ]; then
  echo "run.sh: no JSON object found in job output:" >&2
  echo "$output" >&2
  exit 1
fi

echo "$json_line"
