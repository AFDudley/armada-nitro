#!/usr/bin/env bash
# Runs the armada-watchtower-scenario job against the operator-managed fixturenet E12.
# Holds the deployment path, copies the job's compose file into the deployment's
# compose-jobs (kept in sync each run), then calls laconic-so run-job and prints the
# single JSON line to stdout.
set -euo pipefail

SCENARIO="${SCENARIO:-stale}"

# The operator-managed fixturenet deployment (E12). Never stopped/reset/recreated here.
DEP_DIR="${DEP_DIR:-$HOME/deployments/armada-fixturenet-e12}"
# The job's compose file lives in the repo's stack/compose-jobs; copy it into
# the deployment's compose-jobs each run, so an edited job definition takes effect.
HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HELPER_DIR/.." && pwd)"
JOB_FILE="$REPO_ROOT/stack/compose-jobs/docker-compose-armada-watchtower-scenario.yml"

mkdir -p "$DEP_DIR/compose-jobs"
cp "$JOB_FILE" "$DEP_DIR/compose-jobs/docker-compose-armada-watchtower-scenario.yml"

# laconic-so is a self-contained shiv (a zipapp) that only loads under the system's
# python3.12 (the bare-python3.12 shiv; a PATH lookup would resolve to a pipx wrapper
# that needs its own venv).
LACONIC_SO="/home/rix/bin/laconic-so"
PYTHON="/usr/bin/python3.12"
if [ ! -e "$PYTHON" ]; then
  PYTHON="$(command -v python3.12 || echo python3)"
fi

# Run the job; the orchestrator's run-job (tty=True, non-detached) streams the job's
# own stdout (which also carries the orchestrator's own "Running job: ..." line and any
# docker/compose chatter) to its own stdout. Extract and print only the last line that
# parses as JSON -- the watcher's single-line report -- so scenario.sh's stdout is exactly
# that one line.
output="$(SCENARIO="$SCENARIO" "$PYTHON" "$LACONIC_SO" deployment --dir "$DEP_DIR" run-job armada-watchtower-scenario)"

# The watcher's JSON object can land on the same physical line as preceding chatter (the
# orchestrator's volume-recreate prompt has no trailing newline), so scan for the
# rightmost `{...}` that parses as JSON rather than matching whole lines.
json_line="$(printf '%s' "$output" | "$PYTHON" -c '
import json, sys
data = sys.stdin.read()
idx = data.rfind("{")
while idx != -1:
    candidate = data[idx:].strip()
    try:
        obj = json.loads(candidate)
    except Exception:
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
