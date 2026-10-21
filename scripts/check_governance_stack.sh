#!/usr/bin/env bash
# ABOUTME: G7-deploy (arn-2be) acceptance oracle: stand up the full G1-G6 Baal/Safe
# ABOUTME: governance stack on a fresh fixturenet by reusing the PoC deploy scripts
# ABOUTME: (deploy_crowdfund.ts, deploy_privacy_pool.ts, deploy_revenue_lock_cohort.ts) and
# ABOUTME: the vendored Baal/Safe/Zodiac summon (summon-baal-safe.ts), plus a new Hedgey
# ABOUTME: team-lockup deploy + a G7 allowlist/read-back finalizer. The three new/patched
# ABOUTME: scripts live under env/gates/governance-stack/ (this repo, not the vendored
# ABOUTME: lib/armada-poc submodule) and are copied into the submodule's scripts/ dir at
# ABOUTME: run time -- the same pattern env/gates/nitro-e2e/prepare.ts uses -- so the
# ABOUTME: submodule's pinned commit is never dirtied by this oracle.
# ABOUTME: Emits ONE JSON object to stdout; all progress goes to stderr so the acceptance
# ABOUTME: oracle sees pure JSON. See contracts/specs/derived-arn-2be.spec.json.
set -euo pipefail

err() { echo "check_governance_stack.sh: $*" >&2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- argument parsing: `--fixturenet fresh` ---------------------------------
if [[ "${1:-}" != "--fixturenet" || "${2:-}" != "fresh" ]]; then
  err "usage: $0 --fixturenet fresh"
  exit 1
fi

POC_DIR="$REPO_ROOT/lib/armada-poc"
GATE_SRC="$REPO_ROOT/env/gates/governance-stack"
POC_LOG="$(mktemp)"

# --- copy the new/patched scripts into the (otherwise untouched) submodule ---------------
# Restored on exit so the submodule's working tree is clean again at the pinned commit.
COPIED_FILES=(deploy_hedgey_lockup.ts governance-stack.ts deploy_crowdfund.ts summon-baal-safe.ts)
# --- fixturenet lifecycle (arn-5dd): this gate OWNS the fixturenet it brings up -----------
# Standalone (the arn-2be / arn-d36 deploy gate), it tears the fixturenet down on exit, on
# success and on failure, so a run never leaks a cluster (18 leaked and saturated the host on
# 2026-10-21). A reusing caller that needs the live cluster (check_pool_spend.sh for arn-d62,
# governance-lifecycle.sh for arn-5c3) sets KEEP_FIXTURENET=1 to hold the teardown and owns its
# own. DEP uses $HOME/deployments/<NAME>; NAME/DEP are set below, before any exit that reaches
# the trap after the fixturenet is built.
LACONIC="${LACONIC_SO:-$(command -v laconic-so || true)}"
teardown_fixturenet() {
  [[ "${KEEP_FIXTURENET:-}" == "1" ]] && return 0
  [[ -n "${DEP:-}" && -d "${DEP:-}" ]] || return 0
  err "tearing down fixturenet ${NAME:-?} ..."
  if [[ -n "$LACONIC" ]]; then
    "$LACONIC" deployment --dir "$DEP" down --delete-volumes >/dev/null 2>&1 || true
  fi
  if mountpoint -q "$DEP/data" 2>/dev/null; then
    umount -l "$DEP/data" 2>/dev/null || true
  fi
  rm -rf "$DEP" 2>/dev/null || true
}
cleanup() {
  (cd "$POC_DIR" && git checkout -- scripts/deploy_crowdfund.ts scripts/summon-baal-safe.ts 2>/dev/null || true)
  rm -f "$POC_DIR/scripts/deploy_hedgey_lockup.ts" "$POC_DIR/scripts/governance-stack.ts"
  teardown_fixturenet
}
trap cleanup EXIT
for f in "${COPIED_FILES[@]}"; do
  cp "$GATE_SRC/$f" "$POC_DIR/scripts/$f"
done

# --- 0. Ensure root node_modules (fixturenet-new's base-key needs prettier) ----
if [[ ! -d "$REPO_ROOT/node_modules" ]]; then
  err "installing root node_modules (base-key needs prettier) ..."
  (cd "$REPO_ROOT" && npm ci --no-audit --no-fund) >>"$POC_LOG" 2>&1
fi

# --- 1. Bring up (or reuse) the G7 fixturenet --------------------------------
NAME="armada-fixturenet-governance-$(git rev-parse HEAD)"
DEP="$HOME/deployments/${NAME}"

cluster_id() {
  [[ -f "$DEP/deployment.yml" ]] && awk '/^cluster-id:/{print $2}' "$DEP/deployment.yml"
}

container_up() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

CLUSTER="$(cluster_id || true)"
geth_running=false
if [[ -n "$CLUSTER" ]] && container_up "${CLUSTER}-armada-fixturenet-geth-1"; then
  geth_running=true
  err "reusing running fixturenet ${NAME}"
fi
if ! $geth_running; then
  err "building fresh fixturenet ${NAME} ..."
  bash stack/scripts/fixturenet-new "$NAME" >>"$POC_LOG" 2>&1
  CLUSTER="$(cluster_id || true)"
fi
if [[ -z "$CLUSTER" ]]; then
  err "no cluster-id found for ${NAME}; cannot discover the geth RPC"
  cat "$POC_LOG" >&2
  exit 1
fi

# --- 2. Discover the geth host RPC --------------------------------------------
LINE=$(docker port "${CLUSTER}-armada-fixturenet-geth-1" 8545 | head -n 1)
RPC="http://${LINE#*->}"
export HUB_RPC="$RPC"
err "HUB_RPC=${HUB_RPC}"

# --- 3. Ensure PoC node_modules (install if missing) ---------------------------
if [[ ! -d "$POC_DIR/node_modules" ]]; then
  err "installing PoC node_modules ..."
  (cd "$POC_DIR" && npm ci --no-audit --no-fund) >>"$POC_LOG" 2>&1
fi

# --- 3b. Fetch the pinned armada-circuits artifacts (deploy_privacy_pool needs them) -----
if [[ ! -f "$REPO_ROOT/lib/armada-circuits/build/.fetched-v0.1.0-dev" ]]; then
  err "fetching armada-circuits artifacts ..."
  (cd "$POC_DIR" && bash scripts/fetch-circuits.sh) >>"$POC_LOG" 2>&1
fi

# --- 3c. Fresh-deploy semantics: clear this run's own prior manifests, if any ------------
# (a re-run of this oracle against a reused fixturenet must not load stale addresses from an
# earlier run of THIS deployment; sepolia/mainnet manifests are untouched).
for f in hub-v3.json privacy-pool-hub.json governance-hub.json baal-safe-hub.json \
         crowdfund-hub.json revenue-lock-team.json hedgey-lockup-hub.json \
         governance-stack-hub.json; do
  rm -f "$POC_DIR/deployments/$f"
done

# --- 4. Run the G1-G6 deployment ----------------------------------------------
run_poc() {
  (
    cd "$POC_DIR"
    HUB_RPC="$HUB_RPC" DEPLOY_ENV=local CCTP_MODE=real \
      npx hardhat run "scripts/$1.ts" --network hub
  ) >>"$POC_LOG" 2>&1
}

err "deploy_cctp_v3 (CCTP + USDC)"
run_poc deploy_cctp_v3

err "deploy_privacy_pool"
run_poc deploy_privacy_pool

err "deploy_governance (Safe + ARM + RevenueLock)"
run_poc deploy_governance

err "summon-baal-safe (Baal + ShieldedRagequit + loot)"
run_poc summon-baal-safe

err "deploy_crowdfund (treasury = the Safe)"
run_poc deploy_crowdfund

err "deploy_revenue_lock_cohort (team + airdrop)"
COHORT_NAME="team"
COHORT_FILE="$(mktemp)"
cat > "$COHORT_FILE" <<'JSON'
[
  {"address": "0x2222222222222222222222222222222222222222", "amount": "1000000", "label": "team"},
  {"address": "0x3333333333333333333333333333333333333333", "amount": "400000", "label": "advisors"}
]
JSON
(
  cd "$POC_DIR"
  REVENUE_LOCK_COHORT_NAME="$COHORT_NAME" REVENUE_LOCK_COHORT_FILE="$COHORT_FILE" \
  HUB_RPC="$HUB_RPC" DEPLOY_ENV=local CCTP_MODE=real \
    npx hardhat run scripts/deploy_revenue_lock_cohort.ts --network hub
) >>"$POC_LOG" 2>&1
err "revenue-lock cohort deployed (${COHORT_NAME})"

err "deploy_hedgey_lockup (G5 team lockup)"
run_poc deploy_hedgey_lockup

# --- 5. G7 allowlist + read-back finalizer --------------------------------------
err "governance-stack (allowlist + read-back)"
FINALIZER_OUT=$(cd "$POC_DIR" && \
  HUB_RPC="$HUB_RPC" DEPLOY_ENV=local CCTP_MODE=real \
    npx hardhat run scripts/governance-stack.ts --network hub 2>>"$POC_LOG")
echo "$FINALIZER_OUT" >>"$POC_LOG"

RESULT=$(printf '%s\n' "$FINALIZER_OUT" | grep -oE '^DEPLOY_RESULT_JSON=\{.*\}$' | head -n 1 | sed 's/^DEPLOY_RESULT_JSON=//')
if [[ -z "$RESULT" ]]; then
  err "governance-stack finalizer did not emit DEPLOY_RESULT_JSON; see log at ${POC_LOG}"
  tail -n 100 "$POC_LOG" >&2
  exit 1
fi

# --- 6. Emit the final JSON to stdout -------------------------------------------
echo "$RESULT"
