#!/usr/bin/env bash
# Runs the armada-watchtower-scenario job against the operator-managed fixturenet E12.
# Delegates to the shared job helper (scripts/armada_job_helper.py, arn-895), which builds
# the job's image from this checkout's committed content if it is missing, selects it
# (ARMADA_IMAGE_TAG via `laconic-so deploy create --update`), then calls run-job -- every
# job runner uses this one helper.
set -euo pipefail

SCENARIO="${SCENARIO:-stale}"

# The operator-managed fixturenet deployment (E12). Never stopped/reset/recreated here.
DEP_DIR="${DEP_DIR:-$HOME/deployments/armada-fixturenet-e12}"
HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HELPER_DIR/.." && pwd)"

# laconic-so is a self-contained shiv (a zipapp) that only loads under the system's
# python3.12 (the bare-python3.12 shiv; a PATH lookup would resolve to a pipx wrapper
# that needs its own venv). The shared helper uses the same default; this picks the same
# binary so job-specific invocations (laconic-so, python3.12) stay consistent.
PYTHON="/usr/bin/python3.12"
if [ ! -e "$PYTHON" ]; then
  PYTHON="$(command -v python3.12 || echo python3)"
fi

# The shared helper builds/selects the job's HEAD-sha image, then calls run-job itself
# (inheriting SCENARIO from this script's own environment); its stdout is the job's raw
# stdout (the orchestrator's own "Running job: ..." line, any docker/compose chatter, and
# the watcher's single JSON line).
output="$(ARMADA_IMAGE_DEP_DIR="$DEP_DIR" SCENARIO="$SCENARIO" "$PYTHON" "$HELPER_DIR/armada_job_helper.py" armada-watchtower-scenario)"

# The watcher's JSON object can land on the same physical line as preceding chatter (the
# orchestrator's volume-recreate prompt has no trailing newline), so scan for the
# rightmost `{...}` that parses as JSON rather than matching whole lines.
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
  echo "run-armada-watchtower-scenario: no JSON object found in job output:" >&2
  echo "$output" >&2
  exit 1
fi

echo "$json_line"
