#!/usr/bin/env bash
# Build cerc/armada-nitro-env: Debian bookworm, Foundry v1.8.3, Node 22 + yarn 4.9.2,
# every upstream source pinned via env/sources.lock.json.
source ${CERC_CONTAINER_BASE_DIR}/build-base.sh
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REPO_ROOT=$( cd -- "${SCRIPT_DIR}/../../.." &> /dev/null && pwd )

# The build context includes env/sources.lock.json, so a changed pin rebuilds the image.
docker build -t cerc/armada-nitro-env:local ${build_command_args} \
  -f ${SCRIPT_DIR}/Dockerfile ${REPO_ROOT}
