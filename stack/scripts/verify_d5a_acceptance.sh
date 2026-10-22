#!/usr/bin/env bash
# verify_d5a_acceptance.sh -- arn-bd4 c4
#
# Bring up the REAL fixturenet (via stack/scripts/fixturenet-new) and verify
# every expected service is running. This proves the d5a acceptance is NOT
# weakened by the base-key fix (c4): the real fixturenet still comes up with
# all services running.
#
# Outputs a single-line JSON object:
#   {"real_fixturenet_started": bool, "all_services_running": bool}
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." &>/dev/null && pwd)

# Fixed deployment name for this acceptance run.
NAME="d5a-acceptance"

# arn-bd4 c4: force the COLD path so the d5a acceptance builds a REAL base
# layer from scratch (not a restored snapshot). Remove the base snapshot for
# the current key (the c3 warm-path simulation may have left a marker file
# that is not a real EL-only v2 snapshot, which would break the warm restore).
KEY=$(python3 "${REPO_ROOT}/stack/scripts/base-key.py" --root "${REPO_ROOT}" | sha256sum | cut -c1-16)
rm -f "${HOME}/deployments/.snapshots/armada-fixturenet-base-${KEY}.tar.zst"

# Bring up the real fixturenet: fixturenet-new handles the cold/warm decision,
# starts the chain, and runs the full reconcile (base + armada_nitro + funding).
bash "${REPO_ROOT}/stack/scripts/fixturenet-new" "$NAME"

# After the bring-up, verify every expected service is running.
DEP="${HOME}/deployments/${NAME}"
COMPOSE="${DEP}/compose/docker-compose-armada-fixturenet.yml"
ENVF="${DEP}/config.env"
CLUSTER=$(awk '/^cluster-id:/{print $2}' "${DEP}/deployment.yml")

# Expected services in the real fixturenet (the full chain + validators + nimbus).
SERVICES=(
  armada-fixturenet-genesis
  armada-fixturenet-geth
  armada-fixturenet-beacon
  armada-fixturenet-validator-0
  armada-fixturenet-validator-1
  armada-fixturenet-validator-2
  armada-fixturenet-validator-3
  armada-fixturenet-nimbus-el
  armada-fixturenet-nimbus-cl
)

# The fixturenet is "started" once fixturenet-new completes (chain up + reconciled).
started=true

# Check each expected service is in the "running" state.
all_running=true
for svc in "${SERVICES[@]}"; do
  state=$(docker compose \
      --file "$COMPOSE" \
      --env-file "$ENVF" \
      --project-name "$CLUSTER" \
      ps --format json 2>/dev/null | jq -r --arg svc "$svc" 'map(select(.service == $svc)) | (map(.state) | first // "absent")' 2>/dev/null || true)
  if [ "$state" != "running" ]; then
    all_running=false
  fi
done

# Emit the result as JSON and exit non-zero if any service is not running.
echo "{\"real_fixturenet_started\": ${started}, \"all_services_running\": ${all_running}}"
if [ "$all_running" = true ]; then
  exit 0
else
  exit 1
fi
