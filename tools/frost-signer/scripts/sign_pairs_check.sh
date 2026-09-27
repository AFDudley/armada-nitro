#!/usr/bin/env bash
# Signs the same 32-byte message with each of the three 2-of-3 share pairs
# ({1,2}, {1,3}, {2,3}) and counts how many times `frost-signer sign` printed a
# non-empty signature.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$REPO_ROOT"

cargo build --quiet --manifest-path tools/frost-signer/Cargo.toml
BIN="$REPO_ROOT/tools/frost-signer/target/debug/frost-signer"

OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT

"$BIN" keygen --out "$OUT_DIR" >/dev/null

MESSAGE="0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e"
count=0
for pair in "share-1 share-2" "share-1 share-3" "share-2 share-3"; do
  # shellcheck disable=SC2086
  set -- $pair
  sig="$("$BIN" sign --shares "$OUT_DIR/$1" "$OUT_DIR/$2" --message "$MESSAGE")"
  if [ -n "$sig" ]; then
    count=$((count + 1))
  fi
done

printf '{"signatures_printed_count": %d}\n' "$count"
