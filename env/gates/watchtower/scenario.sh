#!/usr/bin/env bash
# E15a watchtower scenario: runs as a laconic-so job (armada-watchtower-scenario) against
# the operator-managed fixturenet E12, reading the deployment's manifest and test-account
# keys from the mounted /env volume. No host access to the deployment's key files.
#
# Usage: scenario.sh <stale|current>
#   stale   - the counterparty challenges with the older state N (turn 12); the watcher
#              holds the newer state N+1 (turn 13) and answers on-chain with a checkpoint.
#   current - the counterparty challenges with state N (turn 12), which is the same turn the
#              watcher holds; the watcher sees the event but sends no response.
#
# The script calls a helper (in scripts/) that runs the job and prints the job's JSON line.
set -euo pipefail

MODE="${1:?usage: scenario.sh <stale|current>}"

case "$MODE" in
  stale|current) ;;
  *)
    echo "scenario.sh: unknown mode '$MODE' (use stale or current)" >&2
    exit 1
    ;;
esac

TOWER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TOWER_DIR/../../.." && pwd)"
HELPER="$REPO_ROOT/scripts/run-armada-watchtower-scenario.sh"

SCENARIO="$MODE" bash "$HELPER"
