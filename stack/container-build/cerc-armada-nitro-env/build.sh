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
# No `set -u`: the sourced build-base.sh reads optional, possibly-unset CERC_* vars.
set -eo pipefail
source ${CERC_CONTAINER_BASE_DIR}/build-base.sh
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REPO_ROOT=$( cd -- "${SCRIPT_DIR}/../../.." &> /dev/null && pwd )
DOCKERFILE="${SCRIPT_DIR}/Dockerfile"
LOCK="${REPO_ROOT}/env/sources.lock.json"

export DOCKER_BUILDKIT=1

# --build-arg flags from the pins: SRC_<NAME>_{REPO,COMMIT} per source (name
# upper-cased, '-' -> '_'), plus the armada-circuits pins.
build_args=()
while IFS=$'\t' read -r name repo commit; do
  key=$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')
  build_args+=(--build-arg "SRC_${key}_REPO=${repo}" --build-arg "SRC_${key}_COMMIT=${commit}")
done < <(jq -r '.sources[] | [.name, .repo, .commit] | @tsv' "$LOCK")
build_args+=(--build-arg "ARMADA_CIRCUITS_REPO=$(jq -r '."armada-circuits".repo' "$LOCK")")
build_args+=(--build-arg "ARMADA_CIRCUITS_TAG=$(jq -r '."armada-circuits".tag' "$LOCK")")
build_args+=(--build-arg "ARMADA_CIRCUITS_TARBALL_SHA256=$(jq -r '."armada-circuits".tarballSha256' "$LOCK")")
build_args+=(--build-arg "ARMADA_CIRCUITS_SUMS_SHA256=$(jq -r '."armada-circuits".sumsFileSha256' "$LOCK")")

# CERC_FORCE_REBUILD / CERC_CONTAINER_EXTRA_BUILD_ARGS (from build-base.sh).
extra=()
if [ -n "${build_command_args:-}" ]; then read -ra extra <<< "${build_command_args}"; fi

common=("${extra[@]}" "${build_args[@]}" -f "$DOCKERFILE" "$REPO_ROOT")

# Tag the toolchain, each source stage and the circuits stage so the cache key can
# read their image IDs. These share layers with the final build below (BuildKit
# caches by content), so they cost only the tag.
docker build --target toolchain -t cerc/armada-nitro-env-toolchain:local "${common[@]}"
while read -r name; do
  docker build --target "src-${name}" -t "cerc/armada-nitro-env-src-${name}:local" "${common[@]}"
done < <(jq -r '.sources[].name' "$LOCK")
docker build --target circuits -t cerc/armada-nitro-env-circuits:local "${common[@]}"

# The final image.
docker build -t cerc/armada-nitro-env:local "${common[@]}"
