#!/usr/bin/env bash
# N1a acceptance observer. Each subcommand prints exactly one JSON line to stdout and exits 0 on
# a successful observation (the JSON fields themselves carry the pass/fail verdict the spec reads).
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ADJ_ABI_FILE="src/ArmadaNitroAdjudicator.sol:ArmadaNitroAdjudicator"
POOL_ABI_FILE="src/armada/IArmadaPool.sol:IArmadaPool"

bool_json() { # $1: shell truthy (0/1) -> "true"/"false"
  if [ "$1" -eq 0 ]; then echo "true"; else echo "false"; fi
}

cmd="${1:-}"

case "$cmd" in
  holdings-type)
    abi="$(forge inspect "$ADJ_ABI_FILE" abi 2>/dev/null)"
    # holdings(address,bytes32) view returns (TYPE)
    line="$(echo "$abi" | grep -E '\bholdings\(address,bytes32\)' | head -1)"
    type="$(echo "$line" | grep -oE 'returns \([a-zA-Z0-9]+\)' | grep -oE '\([a-zA-Z0-9]+\)' | tr -d '()')"
    printf '{"holdings_value_type": "%s"}\n' "$type"
    ;;

  held-value-empty)
    out="$(forge test --match-test test_heldValue_emptyCommitmentReturnsZero -vv 2>&1)"
    val="$(echo "$out" | grep -oE 'N1A_HELD_VALUE_EMPTY [0-9]+' | awk '{print $2}')"
    passed=0
    echo "$out" | grep -q '^\[PASS\] test_heldValue_emptyCommitmentReturnsZero' || passed=1
    if [ "$passed" -ne 0 ] || [ -z "${val:-}" ]; then
      echo '{"heldValue_empty": -1}'
      exit 1
    fi
    printf '{"heldValue_empty": %s}\n' "$val"
    ;;

  held-value-set)
    out="$(forge test --match-test test_heldValue_setCommitmentReturnsPreimageValueAndFollowsPoolChange -vv 2>&1)"
    passed=0
    echo "$out" | grep -q '^\[PASS\] test_heldValue_setCommitmentReturnsPreimageValueAndFollowsPoolChange' || passed=1
    set_val="$(echo "$out" | grep -oE 'N1A_HELD_VALUE_SET [0-9]+' | awk '{print $2}')"
    follow_val="$(echo "$out" | grep -oE 'N1A_HELD_VALUE_FOLLOWS [0-9]+' | awk '{print $2}')"
    matches=$([ "$passed" -eq 0 ] && [ "${set_val:-}" = "777" ] && echo true || echo false)
    follows=$([ "$passed" -eq 0 ] && [ "${follow_val:-}" = "999" ] && echo true || echo false)
    printf '{"heldValue_set_matches_preimage": %s, "heldValue_follows_pool_change": %s}\n' "$matches" "$follows"
    if [ "$passed" -ne 0 ]; then exit 1; fi
    ;;

  held-value-readers)
    abi="$(forge inspect "$ADJ_ABI_FILE" abi 2>/dev/null)"
    heldvalue_present=1
    echo "$abi" | grep -qE '\bheldValue\(address,bytes32\)' && heldvalue_present=0
    # A "raw holdings amount reader" is source that still treats `holdings[...]` as a uint256
    # amount (an assignment/comparison of a uint256-typed local to the mapping, outside the
    # bytes32-commitment helpers that now own that cast explicitly).
    raw_count=$(grep -rnE '(uint256[[:space:]]+[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*holdings\[|==[[:space:]]*holdings\[|holdings\[[^]]+\]\[[^]]+\][[:space:]]*(\+=|-=))' src/ 2>/dev/null | wc -l | tr -d ' ' || true)
    printf '{"heldValue_in_abi": %s, "raw_holdings_amount_readers": %s}\n' "$(bool_json "$heldvalue_present")" "$raw_count"
    ;;

  deposit-selector)
    out="$(forge test --match-test test_depositSelector_absentFromAdjudicator -vv 2>&1)"
    passed=0
    echo "$out" | grep -q '^\[PASS\] test_depositSelector_absentFromAdjudicator' || passed=1
    call_ok="$(echo "$out" | grep -oE 'N1A_DEPOSIT_SELECTOR_CALL_OK (true|false)' | awk '{print $2}')"
    present="false"
    if [ "$passed" -eq 0 ] && [ "${call_ok:-}" = "true" ]; then present="true"; fi
    printf '{"deposit_selector_present": %s}\n' "$present"
    if [ "$passed" -ne 0 ]; then exit 1; fi
    ;;

  pool-interface)
    abi="$(forge inspect "$POOL_ABI_FILE" abi 2>/dev/null)"
    has_preimage=1
    echo "$abi" | grep -qE '\bpreimageOf\(bytes32\)' && has_preimage=0
    has_owned=1
    echo "$abi" | grep -qE '\btransactOwned\(' && has_owned=0
    printf '{"has_preimageOf": %s, "has_transactOwned": %s}\n' "$(bool_json "$has_preimage")" "$(bool_json "$has_owned")"
    ;;

  safecast-and-events)
    uses_safecast=1
    grep -qE 'SafeCast\.' src/ArmadaNitroAdjudicator.sol src/nitro/MultiAssetHolder.sol 2>/dev/null && uses_safecast=0
    out="$(forge test --match-test test_holdingsChange_emitsDepositedEvent -vv 2>&1)"
    event_ok=1
    echo "$out" | grep -q '^\[PASS\] test_holdingsChange_emitsDepositedEvent' && event_ok=0
    printf '{"uses_safecast": %s, "holdings_change_emits_event": %s}\n' "$(bool_json "$uses_safecast")" "$(bool_json "$event_ok")"
    if [ "$event_ok" -ne 0 ]; then exit 1; fi
    ;;

  full-suite)
    build_exit=0
    forge build >/tmp/n1a_build.log 2>&1 || build_exit=$?
    test_out=""
    test_exit=0
    test_out="$(forge test 2>&1)" || test_exit=$?
    failed="$(echo "$test_out" | grep -oE '[0-9]+ failed' | tail -1 | awk '{print $1}')"
    failed="${failed:-0}"
    if [ "$build_exit" -ne 0 ]; then
      failed=$((failed + 1))
    fi
    printf '{"build_exit": %s, "failed": %s}\n' "$build_exit" "$failed"
    ;;

  *)
    echo "usage: $0 {holdings-type|held-value-empty|held-value-set|held-value-readers|deposit-selector|pool-interface|safecast-and-events|full-suite}" >&2
    exit 2
    ;;
esac
