#!/usr/bin/env bash
# Build cerc/nitro-railgun-foundry: Foundry plus this repository, compiled.
source ${CERC_CONTAINER_BASE_DIR}/build-base.sh
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REPO_ROOT=$( cd -- "${SCRIPT_DIR}/../../.." &> /dev/null && pwd )

docker build -t cerc/nitro-railgun-foundry:local ${build_command_args} \
  -f ${SCRIPT_DIR}/Dockerfile ${REPO_ROOT}
