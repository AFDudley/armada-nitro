#!/usr/bin/env bash
# N4 (request clauses c1-c4): ZkForceMoveApp.stateIsSupported accepts a candidate state only
# when it carries a Groth16 proof that verifies, for the trivial `y = x * x` circuit.
#
# Usage: check_zk_forcemove_app.sh <scenario>
#   valid                   -- a real proof for y=9 (x=3) is supported.
#   wrong_public_input      -- the real proof against the wrong public input (y=10) is refused.
#   mangled_proof            -- a structurally mangled proof (one flipped bit of proof.a.x,
#                               taking the G1 point off-curve) is refused.
#   bad_proof_array_length  -- a `proof` array whose length is not 1 is refused.
#
# Each scenario maps to one forge test in test/ZkForceMoveApp.t.sol. The test itself encodes
# the expected contract behaviour (e.g. `test_refused_whenMangledProof` asserts the specific
# revert `Snark.verify`'s point-validity check throws -- that revert, not caught by
# `stateIsSupported`, is this app's refusal of an unsupported state). This script maps a
# passing test to the `supported` value its name promises; prints one JSON line
# {"supported": true|false} and exits 0 only when the underlying forge test actually passes.
set -uo pipefail
cd "$(dirname "$0")/.."

SCENARIO="${1:-}"

case "$SCENARIO" in
    valid)
        TEST_NAME="test_supported_whenValidProof"
        EXPECTED=true
        ;;
    wrong_public_input)
        TEST_NAME="test_refused_whenWrongPublicInput"
        EXPECTED=false
        ;;
    mangled_proof)
        TEST_NAME="test_refused_whenMangledProof"
        EXPECTED=false
        ;;
    bad_proof_array_length)
        TEST_NAME="test_reverts_whenProofLengthNotOne"
        EXPECTED=false
        ;;
    *)
        echo "usage: $0 {valid|wrong_public_input|mangled_proof|bad_proof_array_length}" >&2
        exit 2
        ;;
esac

FORGE_JSON=$(forge test --match-path test/ZkForceMoveApp.t.sol --match-test "${TEST_NAME}" --json 2>/tmp/check_zk_forcemove_app.stderr)
RC=$?

if [ -s /tmp/check_zk_forcemove_app.stderr ]; then
    echo "=== forge stderr ===" >&2
    cat /tmp/check_zk_forcemove_app.stderr >&2
fi

python3 - "$FORGE_JSON" "$TEST_NAME" "$EXPECTED" << 'PY'
import json
import sys

raw, test_name, expected = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
suites = json.loads(raw) if raw.strip() else {}

passed = False
for suite in suites.values():
    for name, result in suite.get("test_results", {}).items():
        if name.split("(")[0] == test_name:
            passed = result.get("status") == "Success"

if passed:
    print(json.dumps({"supported": expected}))
    sys.exit(0)
else:
    # The test did not pass as expected: report the sentinel opposite of what the scenario
    # claims, so the check fails honestly rather than reporting a fabricated "supported".
    print(json.dumps({"supported": (not expected)}))
    sys.exit(1)
PY
exit $?
