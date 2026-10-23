#!/bin/sh
# Prepare the armada-nitro tree for spec-oracle grading (repo_parameters.json
# environment_command, exo-b380). The oracle runs this once, before any oracle
# subprocess, with HOME set to a fresh scratch home and cwd at the tree root.
#
# Materialize the lib/* submodules at their foundry.lock pins, so forge build
# and forge test run. The judged tree carries gitlinks only.
#
# stack/scripts/base-key.py's TypeScript-normalisation step (_prettier, always
# run -- env/lido/0140-plug-staking-modules-via-vote.ts is an unconditional
# key-input line) needs node_modules/.bin/prettier. A declared_new_entrypoints
# oracle run (e.g. stack/scripts/verify-fixturenet-new-missing-base.sh, arn-46d.1)
# calls base-key.py directly on the host/worktree, separately from the Docker
# commit-boundary gate's own `npm ci`, so this script must install node
# dependencies too. The grading host declares node, npx and npm via
# EXOPHIAL_ORACLE_TOOLCHAIN_BINARIES so they resolve on the oracle's hermetic
# PATH. `--ignore-scripts`: this install only needs prettier on disk, not to run
# any package's postinstall. Not `--offline`: the grading host's own ambient
# EXOPHIAL_ORACLE_DATA_DIRS declares `.npm` so the real npm cache is reachable,
# but a bare `--offline` still risks ENOTCACHED on a cold cache; armada-poc's
# own gate uses the same non-offline `npm ci --legacy-peer-deps` shape.
#
# base-key.py's YAML-canonicalisation step (_yaml_canon) needs PyYAML. This
# is a uv project (pyproject.toml); the oracle's hermetic env puts
# <root>/.venv/bin first on PATH, so a bare `python3` here is the project
# venv, never the host system interpreter -- a venv with no PyYAML synced
# (fresh or stale) fails `import yaml` regardless of what the host's own
# system python3 has. `uv sync --locked` (pyyaml==6.0.1, pyproject.toml
# dependencies) gives the venv the pin stack/scripts/verify_base_key_python_versions.py
# already uses for every OTHER interpreter it checks.
set -e
sh .exophial/gate/fetch-submodules.sh
npm ci --legacy-peer-deps --ignore-scripts
uv sync --locked
