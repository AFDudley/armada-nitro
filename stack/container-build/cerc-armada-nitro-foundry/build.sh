#!/usr/bin/env bash
# Build cerc/armada-nitro-foundry: Foundry plus this repository, compiled.
#
# The build context is 'git archive HEAD' (the committed content only, never
# uncommitted or overlaid files), with each lib/ submodule's committed content
# appended at its gitlink sha. The image is tagged with ARMADA_IMAGE_TAG
# (defaulting to HEAD's commit sha), so the tag matches the commit it was built from.
set -eo pipefail
source ${CERC_CONTAINER_BASE_DIR}/build-base.sh
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REPO_ROOT=$( cd -- "${SCRIPT_DIR}/../../.." &> /dev/null && pwd )

# The final image's tag: ARMADA_IMAGE_TAG if set, else HEAD's commit sha.
IMAGE_TAG="${ARMADA_IMAGE_TAG:-$(git -C "$REPO_ROOT" rev-parse HEAD)}"

# Build context: 'git archive HEAD' (committed content only) + each lib/ submodule's
# committed content at its gitlink sha (git archive leaves submodules as empty
# gitlink directories). `git archive`'s own output ends in a terminator block that a
# plain `>>` concatenation would leave in place, silently truncating everything
# appended after it; `tar --concatenate` strips that terminator from the tar already
# on disk before appending, so the combined tar is read in full.
# The context tar and the submodule tars live in one per-run directory under the
# repo's gitignored .scratch/, never /tmp (a size-capped tmpfs on the host), and
# the directory is removed on exit.
mkdir -p "${REPO_ROOT}/.scratch"
BUILD_SCRATCH="$(mktemp -d "${REPO_ROOT}/.scratch/armada-foundry-build.XXXXXX")"
trap 'rm -rf "$BUILD_SCRATCH"' EXIT
CTX_TAR="${BUILD_SCRATCH}/ctx.tar"
git -C "$REPO_ROOT" archive --format=tar HEAD > "$CTX_TAR"
git -C "$REPO_ROOT" ls-tree HEAD lib/ | while read -r mode type sha name; do
  sub_dir="$REPO_ROOT/$name"
  (
    cd "$REPO_ROOT"
    git submodule update --init -q "$name" 2>/dev/null || true
    if [ -d "$sub_dir" ] && git -C "$sub_dir" rev-parse HEAD >/dev/null 2>/dev/null; then
      sub_tar="$(mktemp -p "$BUILD_SCRATCH")"
      git -C "$sub_dir" archive --format=tar HEAD --prefix="$name/" > "$sub_tar"
      tar --concatenate --file="$CTX_TAR" "$sub_tar"
      rm -f "$sub_tar"
    fi
  )
done

# The Dockerfile is referenced by its path within the committed tree
# (context-relative), and '-' tells docker buildx to read the tarred context from
# stdin.
docker build \
  -t "cerc/armada-nitro-foundry:${IMAGE_TAG}" ${build_command_args} \
  -f "stack/container-build/cerc-armada-nitro-foundry/Dockerfile" - < "$CTX_TAR"
