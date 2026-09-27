#!/usr/bin/env bash
# Asks cargo which version of frost-secp256k1-evm the frost-signer crate actually
# resolves to (from Cargo.lock, the resolver's own record of what was pinned).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$REPO_ROOT"

# `cargo metadata` resolves (and refreshes, if needed) the dependency graph and
# reports the exact versions cargo picked -- the authoritative answer to "what
# version does this crate actually resolve to".
resolved_version="$(
  cargo metadata --quiet --format-version 1 --manifest-path tools/frost-signer/Cargo.toml \
    | python3 -c '
import json, sys
data = json.load(sys.stdin)
for pkg in data["packages"]:
    if pkg["name"] == "frost-secp256k1-evm":
        print(pkg["version"])
        break
'
)"

printf '{"resolved_version": "%s"}\n' "$resolved_version"
