#!/bin/sh
# Prepare the armada-nitro tree for spec-oracle grading. The oracle runs this
# once, before any oracle subprocess (repo_parameters.json environment_command,
# exo-b380), with HOME set to a fresh scratch home and cwd at the tree root.
#
# Two steps:
#  1. Materialize the lib/* submodules at their foundry.lock pins
#     (fetch-submodules.sh), so forge build and forge test run. The judged tree
#     carries gitlinks only.
#  2. Install the node dependencies (npm ci), so the eslint and prettier hooks
#     and the TypeScript app resolve.
#
# npm ci runs ONLINE here. The env-prep step has network (it must, to clone the
# submodules), and package-lock.json pins every version, so the install is
# deterministic. npm ci --offline cannot run: the fresh scratch HOME has no
# ~/.npm cache, so it fails with ENOTCACHED.
set -e
sh .exophial/gate/fetch-submodules.sh
npm ci --legacy-peer-deps
