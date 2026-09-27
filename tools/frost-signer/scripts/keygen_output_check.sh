#!/usr/bin/env bash
# Runs `frost-signer keygen --out <fresh dir>` and reports the shape of what it wrote:
# the count of share-1/2/3 files, whether the group public key file has X and Y, and
# the total number of files in the directory (must be exactly four: no secret file).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$REPO_ROOT"

cargo build --quiet --manifest-path tools/frost-signer/Cargo.toml
BIN="$REPO_ROOT/tools/frost-signer/target/debug/frost-signer"

OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT

"$BIN" keygen --out "$OUT_DIR" >/dev/null

share_count=0
for n in 1 2 3; do
  if [ -f "$OUT_DIR/share-$n" ]; then
    share_count=$((share_count + 1))
  fi
done

total_count=$(find "$OUT_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')

pubkey_file="$OUT_DIR/group-pubkey.json"
has_x=false
has_y=false
if [ -f "$pubkey_file" ]; then
  if grep -q '"x"' "$pubkey_file"; then
    has_x=true
  fi
  if grep -q '"y"' "$pubkey_file"; then
    has_y=true
  fi
fi

printf '{"share_file_count": %d, "pubkey_has_x": %s, "pubkey_has_y": %s, "total_file_count": %d}\n' \
  "$share_count" "$has_x" "$has_y" "$total_count"
