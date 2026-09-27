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

# Print the cache-key input digest lines (before final hashing). Also written
# verbatim into the human-readable .key file so the key is fully auditable.
#
# The lines come from stack/scripts/base-key.py, which normalises every input so
# that a commit which only reformats, re-comments or re-whitespaces a file does
# NOT change the key -- only a change to what the base chain actually deploys
# does. See that script's module docstring for the full include/exclude list and
# the normalisation applied to each file type (image IDs of the toolchain / each
# source / circuits stage + the chain images; reconciler AST with docstrings
# stripped; canonical JSON; parsed TOML/YAML; prettier-normalised TypeScript).
_base_key_lines() {
  local root="$1"
  python3 "${root}/stack/scripts/base-key.py" --root "$root"
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
