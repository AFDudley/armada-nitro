#!/usr/bin/env bash
# N6 acceptance (c6): build the project and run the entire forge test suite.
# The script exits 0 only when the build succeeds and no test is failed.
# It reports the failed count as JSON on stdout: {"failed": <n>}.
set -euo pipefail

# Always operate from the project root (repo root = the directory holding foundry.toml).
cd "$(git rev-parse --show-toplevel)"

# 1. Build the project. Fails the script on any compile error.
#    Forge's build/test output is steered to stderr so that the script's
#    stdout carries ONLY the JSON summary the c6 gate reads.
forge build 1>&2

# 2. Run the full suite, writing structured results to a file.
json_file="$(mktemp)"
# Keep the results for the gate; clean up on exit.
trap 'rm -f "$json_file"' EXIT

# 2b. Run the suite.
forge test --json-file "$json_file" 1>&2

# 3. Summarize: report the number of failed tests as JSON on stdout.
#    "failed" counts only tests whose status is "Failed" (skipped is not a failure).
python3 -c '
import json
d = json.load(open("'"$json_file"'"))
failed = sum(
    1
    for suite in d.values()
    for tr in suite.get("test_results", {}).values()
    if tr.get("status") == "Failed"
)
print(json.dumps({"failed": failed}))
'
