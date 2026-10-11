#!/usr/bin/env bash
# Build cerc/armada-nitro-foundry: Foundry plus this repository, compiled.
#
# The build context is 'git archive HEAD' (the committed content only, never
# uncommitted or overlaid files). The image is tagged with ARMADA_IMAGE_TAG
# (defaulting to HEAD's commit sha), so the tag matches the commit it was built from.
source ${CERC_CONTAINER_BASE_DIR}/build-base.sh
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REPO_ROOT=$( cd -- "${SCRIPT_DIR}/../../.." &> /dev/null && pwd )

# The final image's tag: ARMADA_IMAGE_TAG if set, else HEAD's commit sha.
IMAGE_TAG="${ARMADA_IMAGE_TAG:-$(git -C "$REPO_ROOT" rev-parse HEAD)}"

# Build context: 'git archive HEAD' (committed content only). The Dockerfile is
# referenced by its path within the committed tree (context-relative), and '-'
# tells docker buildx to read the tarred context from stdin.
git -C "$REPO_ROOT" archive --format=tar HEAD | docker build \
  -t "cerc/armada-nitro-foundry:${IMAGE_TAG}" "${build_command_args}" \
  -f "stack/container-build/cerc-armada-nitro-foundry/Dockerfile" -
