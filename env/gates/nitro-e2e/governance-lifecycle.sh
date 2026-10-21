#!/usr/bin/env bash
# ABOUTME: G7a (arn-da4, short-window landing arn-5c3) fixturenet gate step: the first half of
# ABOUTME: the Baal governance lifecycle (crowdfund commit -> finalize -> claim ARM -> delegate ->
# ABOUTME: one Baal vote) against the real G1-G6 contracts on a fresh fixturenet, with a real
# ABOUTME: short crowdfund window and short Baal voting/grace period so the real wait fits the
# ABOUTME: gate's wall clock budget. A sibling step inside the existing armada-nitro-e2e gate
# ABOUTME: directory -- env/gates/nitro-e2e/prepare.ts (channel funding from a shielded note) is
# ABOUTME: untouched; see contracts/specs/derived-arn-5c3.spec.json. Fixturenet only: refuses
# ABOUTME: --network sepolia / --network mainnet before doing anything.
# ABOUTME: Emits ONE JSON object to stdout; all progress goes to stderr.
set -euo pipefail

err() { echo "governance-lifecycle.sh: $*" >&2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

# --report-json is the acceptance oracle's invocation; this script always emits one JSON
# object to stdout, so the flag is accepted and otherwise a no-op. --network names the target;
# this gate stands up its own fresh fixturenet (scripts/check_governance_stack.sh) and refuses to
# run against sepolia or mainnet, before doing anything else (no fixturenet brought up, no key
# exported, no deploy attempted).
NETWORK="fixturenet"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-json) shift ;;
    --network)
      NETWORK="${2:-}"
      shift 2
      ;;
    *)
      err "unknown argument: $1 (usage: $0 [--report-json] [--network fixturenet])"
      exit 1
      ;;
  esac
done
case "$NETWORK" in
  fixturenet) ;;
  sepolia|mainnet)
    err "refusing to run against ${NETWORK}: this gate is fixturenet-only (it deploys its own fresh G1-G6 stack and waits out a real short crowdfund window and Baal voting/grace period -- never point it at a public network)"
    exit 1
    ;;
  *)
    err "unknown --network ${NETWORK} (only fixturenet is supported)"
    exit 1
    ;;
esac

# Deployer key: the fixturenet's premined Anvil/Hardhat account 0
# (lib/armada-poc/hardhat.config.ts's ANVIL_KEY) -- the same key every G1-G6 deploy script in
# scripts/check_governance_stack.sh signs with, and this run's ArmadaToken.initWhitelist already
# allowlisted for ARM transfer (arn-2be's governance-stack.ts).
export DEPLOYER_KEY="${DEPLOYER_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

# Short-window overrides for this fixturenet-only gate. scripts/check_governance_stack.sh's own
# deploy chain (deploy_crowdfund.ts, summon-baal-safe.ts) reads these so both the real crowdfund
# window and the one Baal proposal's voting/grace period finish inside this gate's wall-clock
# budget, instead of ArmadaCrowdfund's real 21-day sale window or Baal's own (0/0, i.e.
# immediate-expiry) defaults.
# CROWDFUND_WINDOW_DURATION: ArmadaCrowdfund's immutable `windowDuration` constructor argument.
export CROWDFUND_WINDOW_DURATION="${CROWDFUND_WINDOW_DURATION:-60}"
# BAAL_VOTING_PERIOD_SECONDS / BAAL_GRACE_PERIOD_SECONDS: Baal.votingPeriod / Baal.gracePeriod,
# set via summon-baal-safe.ts's init multisend (setGovernanceConfig), not a contract change.
export BAAL_VOTING_PERIOD_SECONDS="${BAAL_VOTING_PERIOD_SECONDS:-300}"
export BAAL_GRACE_PERIOD_SECONDS="${BAAL_GRACE_PERIOD_SECONDS:-60}"

# --- fixturenet lifecycle (arn-5dd): this gate OWNS its fixturenet ------------
# It passes KEEP_FIXTURENET=1 to scripts/check_governance_stack.sh below, so the shared deploy
# harness keeps the cluster up for the lifecycle steps instead of tearing it down on its own exit.
# This gate then tears the fixturenet down itself on exit, on success and on failure, so a run
# never leaks a cluster. A caller that reuses this gate and owns the cluster sets KEEP_FIXTURENET=1.
NAME="armada-fixturenet-governance-$(git rev-parse HEAD)"
DEP="$HOME/deployments/${NAME}"
LACONIC="${LACONIC_SO:-$(command -v laconic-so || true)}"
teardown_fixturenet() {
  [[ "${KEEP_FIXTURENET:-}" == "1" ]] && return 0
  [[ -n "${DEP:-}" && -d "${DEP:-}" ]] || return 0
  err "tearing down fixturenet ${NAME} ..."
  if [[ -n "$LACONIC" ]]; then
    "$LACONIC" deployment --dir "$DEP" down --delete-volumes >/dev/null 2>&1 || true
  fi
  if mountpoint -q "$DEP/data" 2>/dev/null; then
    umount -l "$DEP/data" 2>/dev/null || true
  fi
  rm -rf "$DEP" 2>/dev/null || true
}
trap teardown_fixturenet EXIT

# --- 1. Bring up (or reuse) the G7 fixturenet and deploy G1-G6 ---------------
# Reuses scripts/check_governance_stack.sh verbatim (arn-2be's own deploy orchestration: fresh
# fixturenet + deploy_cctp_v3 + deploy_privacy_pool + deploy_governance + summon-baal-safe +
# deploy_crowdfund + deploy_revenue_lock_cohort + deploy_hedgey_lockup + governance-stack) rather
# than re-driving the same eight deploy stages a second time here -- one source of truth for
# "stand up the governance stack on the fixturenet."
err "deploying G1-G6 (scripts/check_governance_stack.sh --fixturenet fresh) ..."
GOV_STACK_JSON=$(KEEP_FIXTURENET=1 bash "$REPO_ROOT/scripts/check_governance_stack.sh" --fixturenet fresh)
err "governance stack: ${GOV_STACK_JSON}"

# check_governance_stack.sh's own deployment naming/discovery (same git-HEAD-keyed name, same
# docker-port RPC lookup), so this step always targets the stack it just deployed (or reused).
NAME="armada-fixturenet-governance-$(git rev-parse HEAD)"
DEP="$HOME/deployments/${NAME}"
CLUSTER="$(awk '/^cluster-id:/{print $2}' "$DEP/deployment.yml")"
if [[ -z "$CLUSTER" ]]; then
  err "no cluster-id found for ${NAME} after check_governance_stack.sh"
  exit 1
fi
LINE=$(docker port "${CLUSTER}-armada-fixturenet-geth-1" 8545 | head -n 1)
export HUB_RPC="http://${LINE#*->}"
err "HUB_RPC=${HUB_RPC}"

POC_DIR="$REPO_ROOT/lib/armada-poc"
export POC_DEPLOYMENTS_DIR="$POC_DIR/deployments"

# --- 2. Run the G7a scenario, one forge script phase at a time --------------
run_scenario() {
  forge script script/GovernanceLifecycle.s.sol --sig "$1()" --rpc-url "$HUB_RPC" --slow --broadcast
}

err "fund (ARM pre-load + whitelist + 67 seeds committing past MIN_SALE)"
run_scenario fund >&2

# windowEnd = windowStart (this run's crowdfund deploy time + CROWDFUND_OPEN_DELAY) +
# CROWDFUND_WINDOW_DURATION (ArmadaCrowdfund's immutable windowDuration constructor argument,
# set short above) -- a real wait against a real geth fixturenet, which has no time-travel RPC
# (unlike Anvil's evm_increaseTime; docs/ENVIRONMENT.md and env/gates/governance-stack/CLAUDE.md
# both note real geth lacks the debug/anvil RPCs this repo's other scenarios would otherwise use).
CROWDFUND_ADDR=$(python3 -c "import json; print(json.load(open('${POC_DEPLOYMENTS_DIR}/crowdfund-hub.json'))['contracts']['crowdfund'])")
WINDOW_END_RAW=$(cast call "$CROWDFUND_ADDR" 'windowEnd()(uint256)' --rpc-url "$HUB_RPC")
WINDOW_END="${WINDOW_END_RAW%% *}"
NOW=$(date +%s)
WAIT=$(( WINDOW_END - NOW + 3 ))
if [[ "$WAIT" -gt 0 ]]; then
  err "waiting ${WAIT}s for the crowdfund's commit window to end on chain (windowEnd=${WINDOW_END})"
  sleep "$WAIT"
fi

err "finalize"
run_scenario finalize >&2

err "claim"
run_scenario claim >&2

err "sponsor"
run_scenario sponsor >&2

err "vote"
run_scenario vote >&2

err "report"
run_scenario report >&2

# --- 3. Emit the final JSON to stdout ----------------------------------------
python3 -c "
import json
with open('${REPO_ROOT}/deployments/governance-lifecycle-report.json') as f:
    report = json.load(f)
report['network'] = 'fixturenet'
report['mocks_used'] = False
print(json.dumps(report))
"
