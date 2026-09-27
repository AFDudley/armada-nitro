#!/usr/bin/env bash
# Scans the tool's own --help text (main command, keygen, sign) for any option that
# would reach another machine over a network or deploy a contract.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$REPO_ROOT"

cargo build --quiet --manifest-path tools/frost-signer/Cargo.toml
BIN="$REPO_ROOT/tools/frost-signer/target/debug/frost-signer"

help_text="$("$BIN" --help)"$'\n'"$("$BIN" keygen --help)"$'\n'"$("$BIN" sign --help)"

network_flag_found=false
if printf '%s' "$help_text" | grep -Eqi -- '--(rpc|host|port|peer|url|endpoint|network|remote|address|connect|server)'; then
  network_flag_found=true
fi

deploy_flag_found=false
if printf '%s' "$help_text" | grep -Eqi -- '--deploy'; then
  deploy_flag_found=true
fi

printf '{"network_flag_found": %s, "deploy_flag_found": %s}\n' "$network_flag_found" "$deploy_flag_found"
