# Shared helpers for the fixturenet base-layer snapshot cache.
# Sourced by fixturenet-base-snapshot and fixturenet-new; not run directly.
#
# The "base layer" is the fixturenet chain plus the third-party infrastructure
# that does not change unless its pinned inputs change: weth, usdc, cctp, aave,
# lido and the armada pool. Building it takes ~24 min. We snapshot the whole
# stopped chain (all data volumes) once and restore it into new deployments, so
# each new fixturenet only deploys armada_nitro + funding (~1 min) on top.
#
# All paths are relative to REPO_ROOT (resolved by the caller) so the cache key
# is independent of where the repo is checked out.

# The modules the base layer deploys, in reconciler order. A deployment is a
# valid snapshot source iff its manifest's gasUsed names exactly these.
BASE_MODULES="aave armada cctp lido usdc weth"   # sorted, for set comparison

# Where snapshots and their key files live.
SNAP_DIR="${HOME}/deployments/.snapshots"

# The base reconcile target, committed at env/targets/fixturenet-base.json, is
# copied into the deployment's armada_env volume (bind-mounted to
# data/armada_env, seen as /env in the job) under this name and selected with
# RECONCILER_TARGET. The image's default target (env/targets/fixturenet.json,
# the full target) is left untouched, so a later full reconcile picks it up.
BASE_TARGET_IN_ENV="reconciler-base-target.json"

# Container image references whose IDs go into the cache key. Read from the
# compose files so a tag bump here follows the tag bump there.
_base_image_refs() {
  local root="$1"
  local compose="${root}/stack/compose/docker-compose-armada-fixturenet.yml"
  local recon="${root}/stack/compose-jobs/docker-compose-armada-env-reconcile.yml"
  grep -oE 'cerc/armada-nitro-env:[^ ]+' "$recon" | head -1
  grep -oE 'ethereum/client-go:[^ ]+' "$compose" | head -1
  grep -oE 'sigp/lighthouse:[^ ]+' "$compose" | head -1
  grep -oE 'ethpandaops/ethereum-genesis-generator:[^ ]+' "$compose" | head -1
}

# Print the cache-key input digest lines (before final hashing). Also used to
# write the human-readable .key file so the key is fully auditable.
#
# The key covers everything that determines the base chain:
#   - env/sources.lock.json            (every upstream source pin)
#   - env/targets/fixturenet-base.json (the base target itself)
#   - env/lido/**                      (lido deploy params, steps, tooling)
#   - env/reconciler/**                (the reconciler + all base modules)
#   - stack/compose/docker-compose-armada-fixturenet.yml
#         (the chain: geth/lighthouse/genesis image tags AND the genesis
#          generator's parameters -- chain id, forks, mnemonic, validators)
#   - stack/compose-jobs/docker-compose-armada-env-reconcile.yml (the job)
#   - the resolved image IDs of the four container images above
_base_key_lines() {
  local root="$1"
  (
    cd "$root"
    # File contents (relative paths -> checkout-location independent).
    find env/reconciler env/lido -type f -not -path '*/__pycache__/*' \
      | LC_ALL=C sort | xargs sha256sum
    sha256sum \
      env/sources.lock.json \
      env/targets/fixturenet-base.json \
      stack/compose/docker-compose-armada-fixturenet.yml \
      stack/compose-jobs/docker-compose-armada-env-reconcile.yml
  )
  # Image identities.
  local ref id
  while read -r ref; do
    [ -n "$ref" ] || continue
    id=$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null || echo "MISSING")
    printf 'image %s %s\n' "$ref" "$id"
  done < <(_base_image_refs "$root")
}

# The 16-hex cache key.
compute_base_key() {
  local root="$1"
  _base_key_lines "$root" | sha256sum | cut -c1-16
}

# Snapshot / key file paths for a given key.
snap_path() { printf '%s/armada-fixturenet-base-%s.tar.zst' "$SNAP_DIR" "$1"; }
key_path()  { printf '%s/armada-fixturenet-base-%s.key' "$SNAP_DIR" "$1"; }

# Assert a deployment's manifest names exactly the base modules (no
# armada_nitro / funding, and none missing). Exits non-zero with a reason.
require_base_only_manifest() {
  local dep="$1"
  local manifest="${dep}/data/armada_env/manifest.json"
  if [ ! -f "$manifest" ]; then
    echo "fixturenet-base-snapshot: no manifest at ${manifest} -- run the base reconcile first" >&2
    return 1
  fi
  local have
  have=$(sudo jq -r '.gasUsed | keys | join(" ")' "$manifest" 2>/dev/null)
  if [ "$have" != "$BASE_MODULES" ]; then
    echo "fixturenet-base-snapshot: manifest gasUsed is '${have}', expected exactly the base modules '${BASE_MODULES}'." >&2
    echo "  A snapshot source must have run ONLY the base target (network + weth,usdc,cctp,aave,lido,armada)." >&2
    return 1
  fi
}
