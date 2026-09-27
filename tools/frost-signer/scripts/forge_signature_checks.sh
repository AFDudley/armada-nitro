#!/usr/bin/env bash
# Regenerates the forge fixture from the frost-signer tool's own keygen + sign logic
# (one signature per 2-of-3 share pair, over a fixed 32-byte message), then runs the
# forge tests that check the frost-secp256k1-evm verifier HubCustodian uses
# (FROST.verifySignature) accepts each pair's signature and rejects it once the
# message changes by one byte.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$REPO_ROOT"

FIXTURE="test/fixtures/frost-signer-fixture.json"
cargo run --quiet --manifest-path tools/frost-signer/Cargo.toml --example gen_forge_fixture -- "$FIXTURE" >/dev/null

forge_json="$(forge test --match-contract FrostSignerTest --json 2>/dev/null)"

python3 -c '
import json, sys

data = json.loads(sys.argv[1])
results = {}
for suite in data.values():
    results.update(suite.get("test_results", {}))

def matches(substr):
    return {name: r for name, r in results.items() if substr in name}

pair_tests = matches("SignatureVerifies")
tamper_tests = matches("RejectsTamperedMessage")

pair_tests_matched = len(pair_tests)
pair_tests_passed = sum(1 for r in pair_tests.values() if r["status"] == "Success")
tamper_test_matched = len(tamper_tests)
tamper_test_passed = sum(1 for r in tamper_tests.values() if r["status"] == "Success")

print(json.dumps({
    "pair_tests_matched": pair_tests_matched,
    "pair_tests_passed": pair_tests_passed,
    "tamper_test_matched": tamper_test_matched,
    "tamper_test_passed": tamper_test_passed,
}))
' "$forge_json"
