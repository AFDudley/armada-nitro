#!/usr/bin/env bash
# ABOUTME: G7b-spend (arn-d62) acceptance oracle: on a fresh fixturenet with the
# ABOUTME: G1-G6 governance stack deployed (via the existing governance-stack harness),
# ABOUTME: shield a note directly into the real pool, spend it with a real Groth16 proof
# ABOUTME: built by the SDK's planSpend (planner) + prove (prover), submit PrivacyPool.transact,
# ABOUTME: and verify the pool recorded a new nullifier and inserted a new commitment.
# ABOUTME: Reuses the existing governance-stack / nitro-e2e fixturenet harness (no new harness);
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

# --- 1. Ensure the G1-G6 governance stack is deployed on a fresh fixturenet ---------
# Reuse the existing governance-stack harness (arn-2be's deploy oracle). It brings up
# (or reuses) the fixturenet, deploys the G1-G6 stack, fetches the circuits, and writes
# the pool manifest. Its stdout (the deploy result JSON) is captured, not emitted here.
HARNESS_LOG="$(mktemp)"
bash scripts/check_governance_stack.sh --fixturenet fresh > "$HARNESS_LOG" 2>&1

# --- 2. Discover the geth RPC (the same docker-port discovery the harness uses) ------
NAME="armada-fixturenet-governance-$(git rev-parse HEAD)"
DEP="$HOME/deployments/${NAME}"
CLUSTER="$(awk '/^cluster-id:/{print $2}' "$DEP/deployment.yml" 2>/dev/null || true)"
if [[ -z "$CLUSTER" ]]; then
  err "no cluster-id for ${NAME}; cannot discover the geth RPC"
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
trap 'rm -f "$POC_DIR/scripts/pool-spend.ts" || true' EXIT

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
