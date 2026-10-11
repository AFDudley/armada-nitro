#!/usr/bin/env bash
# Build cerc/armada-nitro-env: Debian bookworm, Foundry v1.8.3, Node 22 + yarn 4.9.2,
# every upstream source pinned via env/sources.lock.json.
#
# The Dockerfile is split into one BuildKit stage per upstream source (plus a
# toolchain, a circuits and a contracts stage). Each source stage's repo and
# commit are passed in as --build-arg from the pins here, so a change to one
# source's pin rebuilds only that stage. We also tag the toolchain, each source
# stage and the circuits stage (extra --target builds reuse the shared layers, so
# they only add tags) so their image IDs are available to the fixturenet
# base-snapshot cache key (stack/scripts/base-key.py).
#
# The build context is 'git archive HEAD' (the committed content only, never
# uncommitted or overlaid files), with each lib/ submodule's committed content
# appended at its gitlink sha. The final image is tagged with ARMADA_IMAGE_TAG
# (defaulting to HEAD's commit sha), so the image's tag matches the commit it was
# built from.
#
# No `set -u`: the sourced build-base.sh reads optional, possibly-unset CERC_* vars.
set -eo pipefail
source ${CERC_CONTAINER_BASE_DIR}/build-base.sh
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REPO_ROOT=$( cd -- "${SCRIPT_DIR}/../../.." &> /dev/null && pwd )
DOCKERFILE="stack/container-build/cerc-armada-nitro-env/Dockerfile"
LOCK="${REPO_ROOT}/env/sources.lock.json"

# The final image's tag: ARMADA_IMAGE_TAG if set, else HEAD's commit sha.
IMAGE_TAG="${ARMADA_IMAGE_TAG:-$(git -C "$REPO_ROOT" rev-parse HEAD)}"

export DOCKER_BUILDKIT=1

# --- Build context: parent 'git archive HEAD' + each lib/ submodule's committed content.
# The gitlink shas come from the parent's tree (git ls-tree). If a submodule is not
# checked out at its committed sha, fetch it (git submodule update) so the tar is
# complete.
CTX_TAR="/tmp/armada-env-ctx.tar"
git -C "$REPO_ROOT" archive --format=tar HEAD > "$CTX_TAR"
git -C "$REPO_ROOT" ls-tree HEAD lib/ | while read -r mode type sha name; do
  # `name` is the full path `lib/<basename>` (git ls-tree lists children of lib/).
  sub_dir="$REPO_ROOT/$name"
  # Check out the submodule (by its path, as `git submodule` expects) at its
  # committed sha, then append its content to the context tar. `git archive`'s
  # own output ends in a terminator block that a plain `>>` concatenation would
  # leave in place, silently truncating everything appended after it; `tar
  # --concatenate` strips that terminator from the tar already on disk before
  # appending, so the combined tar is read in full.
  (
    cd "$REPO_ROOT"
    git submodule update --init -q "$name" 2>/dev/null || true
    if [ -d "$sub_dir" ] && git -C "$sub_dir" rev-parse HEAD >/dev/null 2>/dev/null; then
      sub_tar="$(mktemp)"
      git -C "$sub_dir" archive --format=tar HEAD --prefix="$name/" > "$sub_tar"
      tar --concatenate --file="$CTX_TAR" "$sub_tar"
      rm -f "$sub_tar"
    fi
  )
done

# --build-arg flags from the pins. Compute the jq values into variables first,
# then assemble the flags (avoiding nested $(jq) inside the array assignment).
circuits_repo=$(jq -r '."armada-circuits".repo' "$LOCK")
circuits_tag=$(jq -r '."armada-circuits".tag' "$LOCK")
circuits_tarball=$(jq -r '."armada-circuits".tarballSha256' "$LOCK")
circuits_sums=$(jq -r '."armada-circuits".sumsFileSha256' "$LOCK")

build_args=()
while IFS=$'\t' read -r name repo commit; do
  key=$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')
  build_args+=(--build-arg "SRC_${key}_REPO=${repo}" --build-arg "SRC_${key}_COMMIT=${commit}")
done < <(jq -r '.sources[] | [.name, .repo, .commit] | @tsv' "$LOCK")
build_args+=(--build-arg "ARMADA_CIRCUITS_REPO=${circuits_repo}"
              --build-arg "ARMADA_CIRCUITS_TAG=${circuits_tag}"
              --build-arg "ARMADA_CIRCUITS_TARBALL_SHA256=${circuits_tarball}"
              --build-arg "ARMADA_CIRCUITS_SUMS_SHA256=${circuits_sums}")

# CERC_FORCE_REBUILD / CERC_CONTAINER_EXTRA_BUILD_ARGS (from build-base.sh).
extra=()
if [ -n "${build_command_args:-}" ]; then read -ra extra <<< "${build_command_args}"; fi

# Build context: 'git archive HEAD' (committed content only, submodules included).
# The toolchain, each source stage, circuits and frost-signer stages keep a shared
# ':local' tag (the base-snapshot cache key, base-key.py reads their image IDs);
# the final image is tagged with the commit sha.

# The toolchain:
docker build --target toolchain -t cerc/armada-nitro-env-toolchain:local "${extra[@]}" "${build_args[@]}" -f "$DOCKERFILE" < "$CTX_TAR" -
# Each source stage (one per env/sources.lock.json sources[] entry).
while read -r name; do
  docker build --target "src-${name}" -t "cerc/armada-nitro-env-src-${name}:local" "${extra[@]}" "${build_args[@]}" -f "$DOCKERFILE" < "$CTX_TAR" -
done < <(jq -r '.sources[].name' "$LOCK")
# The circuits stage.
docker build --target circuits -t cerc/armada-nitro-env-circuits:local "${extra[@]}" "${build_args[@]}" -f "$DOCKERFILE" < "$CTX_TAR" -
# The frost-signer stage (arn-1be).
docker build --target frost-signer -t cerc/armada-nitro-env-frost-signer:local "${extra[@]}" "${build_args[@]}" -f "$DOCKERFILE" < "$CTX_TAR" -
# The final image, tagged with the commit sha.
docker build -t "cerc/armada-nitro-env:${IMAGE_TAG}" "${extra[@]}" "${build_args[@]}" -f "$DOCKERFILE" < "$CTX_TAR" -
