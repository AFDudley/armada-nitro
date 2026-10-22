#!/bin/sh
# Prepare the armada-nitro tree for spec-oracle grading (repo_parameters.json
# environment_command, exo-b380). The oracle runs this once, before any oracle
# subprocess, with HOME set to a fresh scratch home and cwd at the tree root.
#
# Materialize the lib/* submodules at their foundry.lock pins, so forge build
# and forge test run. The judged tree carries gitlinks only.
#
# The oracle runs forge, not the pre-commit hooks, so it needs no node
# dependencies. npm is not on the oracle PATH: the oracle links only the declared
# toolchain binaries (cargo, rustc, forge, cast, anvil, laconic-so), and it never
# runs eslint or prettier. A spec that needs node must declare node and npm as
# toolchain binaries (EXOPHIAL_ORACLE_TOOLCHAIN_BINARIES) and add npm ci here.
set -e
sh .exophial/gate/fetch-submodules.sh
