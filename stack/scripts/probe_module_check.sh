#!/usr/bin/env bash
# probe_module_check.sh <exact_set|extra_module|missing_module>
#
# Build a temp manifest holding the scenario's module set, then run
# fixturenet-new's own module check (extracted from stack/scripts/fixturenet-new)
# against it, and report JSON: {"scenario": <name>, "script_exit": <N>}.
#
# The expected set is the full target's modules (env/targets/fixturenet.json,
# every key except "network"), the same input fixturenet-new's check reads.
#
# The probe itself always exits 0 (spec: the script's exit_code must be 0);
# "script_exit" is what fixturenet-new would have exited with:
#   exact_set       -> manifest holds the target's modules exactly -> check passes -> 0
#   extra_module    -> one module in addition to the target's      -> check fails  -> 1
#   missing_module  -> one of the target's modules is missing      -> check fails  -> 1
set -euo pipefail

usage() { echo "usage: $0 <exact_set|extra_module|missing_module>" >&2; exit 1; }
[ $# -eq 1 ] || usage

SCENARIO="$1"
case "$SCENARIO" in
  exact_set|extra_module|missing_module) ;;
  *) echo "probe_module_check: unknown scenario '${SCENARIO}'" >&2; exit 1 ;;
esac

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." &>/dev/null && pwd)
SCRIPT="${REPO_ROOT}/stack/scripts/fixturenet-new"
TARGET="${REPO_ROOT}/env/targets/fixturenet.json"

EXPECTED_JSON=$(jq -c '[keys[] | select(. != "network")]' "$TARGET")

# Scenario module set:
#   exact_set       -> exactly the target's modules
#   extra_module    -> the target's modules + "swap"
#   missing_module  -> the target's modules minus "usdc"
MODULES_JSON=$(
  case "$SCENARIO" in
    exact_set)
      echo "$EXPECTED_JSON" ;;
    extra_module)
      jq -cn --argjson e "$EXPECTED_JSON" '$e + ["swap"]' ;;
    missing_module)
      jq -cn --argjson e "$EXPECTED_JSON" '$e | map(select(. != "usdc"))' ;;
  esac
)

# Build a temp manifest holding the scenario's modules under .gasUsed.
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
MANIFEST="$TMPD/manifest.json"
python3 -c 'import json,sys; mods=json.loads(sys.argv[1]); gas={}; [gas.update({m:0}) for m in mods]; print(json.dumps({"gasUsed":gas}))' "$MODULES_JSON" > "$MANIFEST"

# Extract fixturenet-new's own check function and run it against the manifest.
CHECK_SRC=$(awk '/^check_module_set\(\) \{/,/^\}/' "$SCRIPT")
HARNESS="$TMPD/probe-harness.sh"
{
  echo '#!/usr/bin/env bash'
  echo "$CHECK_SRC"
  echo "check_module_set \"$MANIFEST\" \"$TARGET\""
} > "$HARNESS"

# The check's exit code is what fixturenet-new would exit with; the probe itself
# always exits 0 (the spec's exit_code assertion).
SCRIPT_EXIT=0
bash "$HARNESS" || SCRIPT_EXIT=$?

# Report: {"scenario": <name>, "script_exit": <N>}.
jq -cn --arg s "$SCENARIO" --argjson x "$SCRIPT_EXIT" '{ "scenario": $s, "script_exit": $x }'
