#!/usr/bin/env bash
# N4 (request clause c9): adding ZkForceMoveApp touches no vendored nitro file, no asset
# file, no existing pool file, and no adjudicator file.
#
# Compares the current branch against `main` and counts files whose content was MODIFIED or
# DELETED (not newly added -- bringing a new file into existence in a previously-untouched
# subtree is not "touching" an existing file) under any of:
#   - src/nitro/**                                      (vendored go-nitro, kept byte-identical)
#   - src/armada/**                                      (Armada's asset/token type definitions)
#   - lib/armada-poc/contracts/privacy-pool/**            (the pool; N4 only ADDS new types
#                                                          files there for the Snark library the
#                                                          app and the pool now share)
#   - src/ArmadaNitroAdjudicator.sol                      (the adjudicator)
#
# Prints one JSON line {"forbidden_changes": N} and exits 0 iff N == 0.
set -uo pipefail
cd "$(dirname "$0")/.."

BASE="main"
if ! git rev-parse --verify "$BASE" >/dev/null 2>&1; then
    echo "check_zk_forcemove_scope: no local '$BASE' ref to diff against" >&2
    echo '{"forbidden_changes": -1}'
    exit 1
fi

DIFF=$(git diff --name-status "${BASE}...HEAD")

FORBIDDEN_FILES=()
while IFS=$'\t' read -r status path rest; do
    [ -z "$status" ] && continue
    # Only M (modified) and D (deleted) count; A (added) does not -- a new file in a
    # previously-untouched subtree was not "touched".
    case "$status" in
        M*|D*) ;;
        *) continue ;;
    esac
    case "$path" in
        src/nitro/*|src/armada/*|lib/armada-poc/contracts/privacy-pool/*|src/ArmadaNitroAdjudicator.sol)
            FORBIDDEN_FILES+=("$path")
            ;;
    esac
done <<< "$DIFF"

COUNT=${#FORBIDDEN_FILES[@]}
if [ "$COUNT" -gt 0 ]; then
    printf 'forbidden changes:\n' >&2
    printf '  %s\n' "${FORBIDDEN_FILES[@]}" >&2
fi

printf '{"forbidden_changes": %d}\n' "$COUNT"
[ "$COUNT" -eq 0 ]
