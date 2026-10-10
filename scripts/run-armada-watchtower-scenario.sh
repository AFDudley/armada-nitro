#!/usr/bin/env bash
# Runs the armada-watchtower-scenario job against the operator-managed fixturenet E12.
# Holds the deployment path, copies the job's compose file into the deployment's
# compose-jobs (kept in sync each run), then calls laconic-so run-job and prints the
# single JSON line to stdout.
set -euo pipefail

SCENARIO="${SCENARIO:-stale}"

# The operator-managed fixturenet deployment (E12). Never stopped/reset/recreated here.
DEP_DIR="${DEP_DIR:-$HOME/deployments/armada-fixturenet-e12}"
HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HELPER_DIR/.." && pwd)"

# laconic-so is a self-contained shiv (a zipapp) that only loads under the system's
# python3.12 (the bare-python3.12 shiv; a PATH lookup would resolve to a pipx wrapper
# that needs its own venv).
LACONIC_SO="/home/rix/bin/laconic-so"
PYTHON="/usr/bin/python3.12"
if [ ! -e "$PYTHON" ]; then
  PYTHON="$(command -v python3.12 || echo python3)"
fi

# Sync the deployment's generated files (compose, compose-jobs) with this checkout's
# stack, so the job definition takes effect: laconic-so's own `deploy create --update`,
# which rewrites each job's volumes for the deployment and leaves data/ and config.env
# alone (copying a raw job file in instead makes compose prompt to recreate volumes).
(cd "$REPO_ROOT" && "$PYTHON" "$LACONIC_SO" --stack stack/stacks/armada-nitro-fixturenet \
  deploy create --spec-file "${DEP_DIR}-spec.yml" --deployment-dir "$DEP_DIR" --update) >&2

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
