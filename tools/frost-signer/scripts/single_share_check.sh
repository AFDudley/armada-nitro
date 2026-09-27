#!/usr/bin/env bash
# Tries to sign with only one key-share file. Prints whether the tool's error names
# the threshold, then exits with the tool's own exit code (non-zero on the expected
# refusal), so both the exit code and the JSON reflect the real behavior of the
# `frost-signer sign` command.
set -uo pipefail
# NOTE: no `set -e`: we must capture a deliberately non-zero exit, not abort on it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$REPO_ROOT"

cargo build --quiet --manifest-path tools/frost-signer/Cargo.toml
BIN="$REPO_ROOT/tools/frost-signer/target/debug/frost-signer"

OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT

"$BIN" keygen --out "$OUT_DIR" >/dev/null

MESSAGE="0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e"
stderr_file="$(mktemp)"
trap 'rm -rf "$OUT_DIR"; rm -f "$stderr_file"' EXIT
"$BIN" sign --shares "$OUT_DIR/share-1" --message "$MESSAGE" >/dev/null 2>"$stderr_file"
tool_exit=$?

mentions_threshold=false
if grep -qi 'threshold' "$stderr_file"; then
  mentions_threshold=true
fi

printf '{"error_mentions_threshold": %s}\n' "$mentions_threshold"

exit "$tool_exit"
