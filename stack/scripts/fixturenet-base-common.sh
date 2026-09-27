# Shared helpers for the fixturenet base-layer snapshot cache.
# Sourced by fixturenet-base-snapshot and fixturenet-new; not run directly.
#
# The "base layer" is the fixturenet chain plus the third-party infrastructure
# that does not change unless its pinned inputs change: weth, usdc, cctp, aave,
# lido and the armada pool. Building it takes ~24 min. We snapshot it once and
# restore it into new deployments, so each new fixturenet only deploys
# armada_nitro + funding (~1 min) on top.
#
# The snapshot is execution-layer only (format v2): geth's data dir, the
# armada_env state, the EL genesis (genesis.json + jwt) and the recorded EL head
# block. It deliberately does NOT include the beacon, the four validators or the
# consensus genesis (genesis.ssz). On restore the consensus genesis is
# regenerated as a shadow fork on the recorded head with GENESIS_TIMESTAMP=now
# (the genesis container's SHADOW_FORK_FILE support), so the beacon starts at
# slot 0 on geth's head and there is never a slot gap -- however old the snapshot
# is. geth keeps its full history and block numbers (Lido's MiniMe checkpoints
# depend on them, so we must NOT bake state into a fresh EL genesis). This mirrors
# stack-orchestrator's fixturenet-eth run-cl.sh, which resets the beacon genesis
# time to now on every fresh start (genesis/cl/reset_genesis_time.sh).
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

# --- EL-only snapshot layout (format v2) ------------------------------------
# Everything below describes the execution-layer-only snapshot: what goes in the
# tar, and how a restore puts it back and hands the recorded head to the genesis
# container's shadow-fork step.

# Volume dirs under <dep>/data captured whole.
SNAP_EL_VOLUMES="geth_data armada_env"
# EL parts of the genesis volume captured (everything geth needs). The CL parts
# (genesis.ssz, config.yaml, mnemonics.yaml, ...) are regenerated at restore.
SNAP_GENESIS_EL_PATHS="armada_fixturenet_genesis/metadata/genesis.json armada_fixturenet_genesis/jwt/jwtsecret"
# The recorded EL head block, stored at the tar root. Its presence is what marks
# a tar as format v2; restore refuses a tar without it.
SNAP_HEAD_FILE="head-block.json"
# On restore the head block is dropped into the genesis volume under this name so
# the genesis container reads it as /data/shadow-fork-block.json (SHADOW_FORK_FILE).
SNAP_SHADOW_FORK_BASENAME="shadow-fork-block.json"
# Every chain volume dir docker bind-mounts. On restore the CL ones start empty:
# a fresh beacon + fresh validators build new databases on the regenerated
# genesis (new genesis_validators_root => fresh slashing-protection DBs).
SNAP_ALL_VOLUMES="armada_fixturenet_genesis geth_data beacon_data validator_0_data validator_1_data validator_2_data validator_3_data armada_env"
# The consensus-layer services (halting these halts block production; geth then
# produces nothing, so its head is final and we can record it).
CL_SERVICES="armada-fixturenet-beacon armada-fixturenet-validator-0 armada-fixturenet-validator-1 armada-fixturenet-validator-2 armada-fixturenet-validator-3"

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

# --- driving docker compose for a deployment --------------------------------
# laconic-so's own `deployment stop` runs `docker compose down` on ALL services,
# but the snapshot needs per-service control: halt the CL, read geth's final
# head, then stop geth. We drive docker compose directly, reusing the exact
# compose file / env-file / project name laconic-so generated for the deployment.
dc_project() { grep -E '^cluster-id:' "$1/deployment.yml" | awk '{print $2}'; }
dc() {  # dc <dep> <docker-compose-args...>
  local dep="$1"; shift
  docker compose \
    --file "${dep}/compose/docker-compose-armada-fixturenet.yml" \
    --env-file "${dep}/config.env" \
    --project-name "$(dc_project "$dep")" \
    "$@"
}

# Record geth's final head block to stdout as the shadow-fork file: the FULL
# JSON-RPC response of eth_getBlockByNumber("latest", false), i.e.
# {"jsonrpc":"2.0","id":1,"result":{...block...}}. eth-genesis-state-generator's
# --shadow-fork-block reads the `.result` field out of that wrapper (see
# eth-beacon-genesis eth1/block.go LoadBlockFromFile -> JSONData.Result), so the
# bare result object alone makes it fail with "unexpected end of JSON input".
# The caller MUST have already halted block production (stopped the CL) so no new
# blocks arrive; we poll until the head is non-null and unchanged across two reads
# (the live geth's forkchoice head can momentarily read null while the CL
# container shuts down), so the recorded block is exactly what geth's next
# graceful stop persists.
capture_head_block() {  # capture_head_block <rpc-url>  -> head JSON-RPC response on stdout
  local rpc="$1" deadline last="" cur resp
  deadline=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    resp=$(curl -s --max-time 5 -H 'Content-Type: application/json' \
      --data '{"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":["latest",false]}' \
      "$rpc" 2>/dev/null || true)
    cur=$(printf '%s' "$resp" | jq -r '.result.number // empty' 2>/dev/null || true)
    if [ -n "$cur" ] && [ "$cur" = "$last" ]; then
      printf '%s' "$resp" | jq '{jsonrpc,id,result}'
      return 0
    fi
    last="$cur"
    sleep 3
  done
  echo "capture_head_block: head never stabilised on ${rpc}" >&2
  return 1
}

# True iff the tar is a format-v2 (EL-only) snapshot: it contains the recorded
# head block at its root.
snapshot_is_v2() {  # snapshot_is_v2 <snapshot.tar.zst>
  zstd -dc "$1" 2>/dev/null | tar -tf - 2>/dev/null | grep -qx "$SNAP_HEAD_FILE"
}

# Restore an EL-only (format v2) snapshot into a deployment's data dir: put
# geth's data, the armada_env state and the EL genesis back, drop the recorded
# head where the genesis container's shadow-fork step reads it, and (re)create the
# empty CL volume dirs so a fresh beacon + validators build their databases on the
# regenerated, shadow-forked genesis. Does NOT start anything.
restore_snapshot() {  # restore_snapshot <dep> <snapshot.tar.zst>
  local dep="$1" snap="$2" data="$1/data"
  [ -f "$snap" ] || { echo "restore_snapshot: no snapshot at $snap" >&2; return 1; }
  if ! snapshot_is_v2 "$snap"; then
    echo "restore_snapshot: $snap has no ${SNAP_HEAD_FILE} -- not an EL-only (v2) snapshot; refusing to restore." >&2
    return 1
  fi
  sudo find "$data" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  zstd -dc "$snap" | sudo tar -C "$data" -xf -
  sudo mv "${data}/${SNAP_HEAD_FILE}" \
          "${data}/armada_fixturenet_genesis/${SNAP_SHADOW_FORK_BASENAME}"
  local v
  for v in $SNAP_ALL_VOLUMES; do sudo mkdir -p "${data}/${v}"; done
}
