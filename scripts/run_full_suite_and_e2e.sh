#!/usr/bin/env bash
# N3 (clause c6): the full contract test suite and the armada-nitro-e2e gate run on a
# fresh test network. Both must finish with no failures.
#
#   stage 1: `forge test` -- the whole suite (no --match-contract filter).
#   stage 2: a fresh fixturenet (stack/scripts/fixturenet-new, the same cold/warm-cache
#            tool every other gate in this repo uses to get "a fresh test network"),
#            then the `armada-nitro-e2e` job on it -- script/FixturenetScenario.s.sol's
#            cooperative close + force close, which is exactly where N3's change lands
#            (concludeAndTransferAllAssets finalize-only, transferAllAssets closed, every
#            payout through transfer(assetIndex, ...)).
#
# Prints one JSON line: {"forge_failed": N, "e2e_failed": N}. Exits 0 iff this script
# itself ran to completion (both stages attempted); a non-zero forge_failed/e2e_failed
# is reported in the JSON, not via the exit code -- the acceptance oracle checks those
# fields itself.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

FIXTURENET_NAME="${FIXTURENET_NAME:-armada-fixturenet-n3-$(date +%s)}"

# ---------------------------------------------------------------- stage 1: forge test
FORGE_JSON=$(forge test --json 2>/tmp/run_full_suite_and_e2e.forge.stderr)
FORGE_RC=$?
if [ -s /tmp/run_full_suite_and_e2e.forge.stderr ]; then
    echo "=== forge test stderr ===" >&2
    cat /tmp/run_full_suite_and_e2e.forge.stderr >&2
fi

if [ "$FORGE_RC" -ne 0 ] && [ -z "$FORGE_JSON" ]; then
    # forge itself failed to run (e.g. a compile error) before producing any JSON.
    FORGE_FAILED=1
else
    FORGE_FAILED=$(python3 - "$FORGE_JSON" << 'PY'
import json
import sys

raw = sys.argv[1]
suites = json.loads(raw) if raw.strip() else {}
failed = 0
for suite in suites.values():
    for result in suite.get("test_results", {}).values():
        if result.get("status") not in ("Success", "Skipped"):
            failed += 1
print(failed)
PY
)
fi

# ---------------------------------------------------------------- stage 2: armada-nitro-e2e
# Build/start a fresh fixturenet (cold base build if no cached snapshot; warm restore
# otherwise), tagging images from this checkout's committed HEAD (git archive).
E2E_FAILED=1
if bash "${REPO_ROOT}/stack/scripts/fixturenet-new" "$FIXTURENET_NAME" \
    > /tmp/run_full_suite_and_e2e.fixturenet.log 2>&1; then
    DEP="${HOME}/deployments/${FIXTURENET_NAME}"
    LACONIC="${LACONIC_SO:-$(command -v laconic-so || true)}"
    export ARMADA_IMAGE_TAG
    ARMADA_IMAGE_TAG=$(git -C "$REPO_ROOT" rev-parse HEAD)
    if "$LACONIC" deployment --dir "$DEP" run-job armada-nitro-e2e \
        > /tmp/run_full_suite_and_e2e.e2e.log 2>&1; then
        E2E_FAILED=0
    else
        E2E_FAILED=1
    fi
    echo "=== armada-nitro-e2e job output ===" >&2
    cat /tmp/run_full_suite_and_e2e.e2e.log >&2
else
    echo "=== fixturenet-new failed ===" >&2
    cat /tmp/run_full_suite_and_e2e.fixturenet.log >&2
fi

python3 - "$FORGE_FAILED" "$E2E_FAILED" << 'PY'
import json
import sys

print(json.dumps({"forge_failed": int(sys.argv[1]), "e2e_failed": int(sys.argv[2])}))
PY
exit 0
