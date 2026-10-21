#!/usr/bin/env bash
# ABOUTME: G7b-spend (arn-d62) acceptance oracle: on a fresh fixturenet with the
# ABOUTME: G1-G6 governance stack deployed (via the existing governance-stack harness),
# ABOUTME: shield a note directly into the real pool, spend it with a real Groth16 proof
# ABOUTME: built by the SDK's planSpend (planner) + prove (prover), submit PrivacyPool.transact,
# ABOUTME: and verify the pool recorded a new nullifier and inserted a new commitment.
# ABOUTME: Brings up its OWN fixturenet and TEARS IT DOWN on exit (no leak);
# ABOUTME: emits ONE JSON object to stdout. Refuses sepolia / mainnet targets (fixturenet only).
# ABOUTME: See contracts/specs/derived-arn-d62.spec.json.
set -euo pipefail

err() { echo "check_pool_spend.sh: $*" >&2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- argument parsing: `--target <fixturenet|sepolia|mainnet>` ----------------
if [[ "${1:-}" != "--target" ]]; then
  err "usage: $0 --target <fixturenet|sepolia|mainnet>"
  err "target ${2:-} must be fixturenet (sepolia/mainnet not supported)"
  exit 1
fi
TARGET="${2:-}"

case "$TARGET" in
  fixturenet)
    : ;;
  sepolia|mainnet)
    err "target ${TARGET} not supported: the pool-spend gate runs on fixturenet only"
    exit 1
    ;;
  "")
    err "missing target (expected fixturenet|sepolia|mainnet)"
    exit 1
    ;;
  *)
    err "unknown target ${TARGET} (expected fixturenet|sepolia|mainnet)"
    exit 1
    ;;
esac

POC_DIR="$REPO_ROOT/lib/armada-poc"
GATE_SRC="$REPO_ROOT/env/gates/pool-spend/pool-spend.ts"

# --- fixturenet lifecycle (arn-d62 defect fix) --------------------------------
# This gate OWNS the fixturenet it brings up. It tears the fixturenet down on exit
# (success OR failure), so a run never leaks a cluster -- the leak that left 18
# fixturenets saturating the host on 2026-10-21. It also tears down any stale
# deployment of the SAME name BEFORE it deploys, so a fresh run never reuses or
# depends on another run's fixturenet state (the collision that made the gate
# re-run fail fast against the worker's still-running fixturenet).
NAME="armada-fixturenet-governance-$(git rev-parse HEAD)"
DEP="$HOME/deployments/${NAME}"
LACONIC="${LACONIC_SO:-$(command -v laconic-so || true)}"

teardown_fixturenet() {
  [[ -d "$DEP" ]] || return 0
  err "tearing down fixturenet ${NAME} ..."
  if [[ -n "$LACONIC" ]]; then
    "$LACONIC" deployment --dir "$DEP" down --delete-volumes >/dev/null 2>&1 || true
  fi
  if mountpoint -q "$DEP/data" 2>/dev/null; then
    umount -l "$DEP/data" 2>/dev/null || true
  fi
  rm -rf "$DEP" 2>/dev/null || true
}

cleanup() {
  rm -f "$POC_DIR/scripts/pool-spend.ts" 2>/dev/null || true
  teardown_fixturenet
}
trap cleanup EXIT

# --- 0. Ensure the vendored PoC submodule is checked out -------------------
# A fresh worktree has an empty submodule dir; the harness + gate need its
# scripts/ dir (the gate copies files there). If already initialized, this is a
# fast no-op.
if git -C "$REPO_ROOT" submodule update --init -- lib/armada-poc; then :; fi

# --- 1. Deploy the G1-G6 governance stack on a FRESH fixturenet ---------------
# Reuse the existing governance-stack harness (arn-2be's deploy oracle). It brings
# up the fixturenet, deploys the G1-G6 stack, fetches the circuits, and writes the
# pool manifest; its own cleanup only restores the submodule scripts, so it leaves
# the fixturenet up for us -- this gate owns the teardown. Clear any stale same-name
# deployment first so the harness builds fresh (never reuses another run's state).
teardown_fixturenet
HARNESS_LOG="$(mktemp)"
KEEP_FIXTURENET=1 bash scripts/check_governance_stack.sh --fixturenet fresh > "$HARNESS_LOG" 2>&1

# --- 2. Discover the geth RPC (the same docker-port discovery the harness uses) ------
CLUSTER="$(awk '/^cluster-id:/{print $2}' "$DEP/deployment.yml" 2>/dev/null || true)"
if [[ -z "$CLUSTER" ]]; then
  err "no cluster-id for ${NAME}; cannot discover the geth RPC"
  tail -n 40 "$HARNESS_LOG" >&2
  exit 1
fi

GETH_CONTAINER="${CLUSTER}-armada-fixturenet-geth-1"
RPC_LINE="$(docker port "$GETH_CONTAINER" 8545 | head -n1)"
HUB_RPC="http://${RPC_LINE#*->}"

# --- 3. Run the pool-spend gate (copy into the PoC scripts/ dir, then hardhat) -------
# The gate: reads the pool manifest + the reconciler's testAccounts, shields a note
# directly into the real pool, builds a real Groth16 proof via the SDK's planSpend +
# prove, submits PrivacyPool.transact, and verifies the new nullifier + commitment.
cp "$GATE_SRC" "$POC_DIR/scripts/pool-spend.ts"

# The gate writes its result to a JSON file (kept so the oracle reads pure JSON).
RESULT_FILE="$POC_DIR/deployments/pool-spend-result.json"
rm -f "$RESULT_FILE"
GATE_LOG="$(mktemp)"
(
  cd "$POC_DIR"
  HUB_RPC="$HUB_RPC" DEPLOY_ENV=local CCTP_MODE=real \
    npx hardhat run scripts/pool-spend.ts --network hub
) > "$GATE_LOG" 2>&1
if [[ ! -f "$RESULT_FILE" ]]; then
  err "gate did not write ${RESULT_FILE}"
  tail -n 40 "$GATE_LOG" >&2
  exit 1
fi

# --- 4. Emit the spend result JSON to stdout ----------------------------------
cat "$RESULT_FILE"
