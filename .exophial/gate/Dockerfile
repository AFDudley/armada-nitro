# armada-nitro commit-boundary gate image (D49, ADR
# exophial/docs/decisions/2026-10-14-gate-runs-in-a-container-built-from-the-judged-commit.md).
#
# gate_container.build_gate_image builds this image from the judged commit's
# own tree: a tar (git archive, with .git and .scratch excluded, the
# .exophial/gate and config overlay paths taken from the integration tip)
# streamed to `docker build --quiet -f .exophial/gate/Dockerfile -`.
# gate_container.run_in_container then runs the configured gate.command
# (`sh -c 'npm ci --legacy-peer-deps --offline && pre-commit run --all-files'`)
# as the sole process: `docker run --rm -i --privileged`, NO -v, NO -e. The
# image's own ENV / HOME / WORKDIR are all the container sees (D49.5/D49.6).
#
# So every toolchain the committed .pre-commit-config.yaml hooks invoke is
# IMAGE CONTENT, pinned to the versions the host runs today:
#   python 3.12 + uv + git + the exophial wheel  -> from exophial-e2e-base
#       (the console scripts claude-md-coverage and reroute-main-commit call:
#        exophial-check-claude-md, exophial-reroute-main-commit)
#   node 24.18.0 + npm 11.16.0                    -> eslint, prettier, npm ci
#   rust 1.88.0 + rustfmt + clippy                -> the fmt and clippy hooks
#   foundry forge/cast/anvil v1.8.3               -> the forge build/test hook
#   psmisc (fuser)                                -> arn-eb0 check-fixturenet-tmpfs-teardown.py
#       and stack/scripts/fixturenet-teardown, which probe a tmpfs mount's live
#       holder the same way the host does
#   lib/* submodules at the foundry.lock pins     -> forge build/test
#   the pre-commit hook environments + npm cache  -> so the run is offline
FROM exophial-e2e-base

USER root
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl xz-utils ca-certificates build-essential pkg-config psmisc \
    && rm -rf /var/lib/apt/lists/*

# --- Node 24.18.0 + npm 11.16.0 (the host's versions) ---
RUN curl -fsSL https://nodejs.org/dist/v24.18.0/node-v24.18.0-linux-x64.tar.xz \
        | tar -xJ -C /usr/local --strip-components=1 \
    && npm install -g npm@11.16.0

# --- Rust 1.88.0 + rustfmt + clippy ---
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --no-modify-path --default-toolchain 1.88.0 \
            --profile minimal -c rustfmt -c clippy
ENV PATH="/usr/local/cargo/bin:${PATH}"

# --- Foundry forge/cast/anvil v1.8.3 (the official pinned image's binaries) ---
COPY --from=ghcr.io/foundry-rs/foundry:v1.8.3 \
        /usr/local/bin/forge /usr/local/bin/cast /usr/local/bin/anvil \
        /usr/local/bin/

# --- pre-commit 4.5.1 (the host's version) on PATH via uv tool, alongside the
#     exophial console scripts the base already installs (exophial-check-claude-md,
#     exophial-reroute-main-commit) that the local hooks call. ---
RUN uv tool install pre-commit==4.5.1

# --- PyYAML 6.0.1, pinned to stack/scripts/verify_base_key_python_versions.py's
#     PINNED_PYYAML. stack/scripts/base-key.py (sourced by fixturenet-base-common.sh,
#     and its verify_base_key_* gate checks) parses YAML compose files with it; the
#     base image's python3 has no PyYAML by default. ---
RUN python3 -m pip install --break-system-packages pyyaml==6.0.1

WORKDIR /gate
COPY . .

# --- lib/* submodules at the foundry.lock pins. The judged tree carries only
#     gitlinks (no submodule content, no .git), so fetch them here where the
#     build has network; the gate run is then offline (npm ci --offline too). ---
RUN sh .exophial/gate/fetch-submodules.sh

# --- npm cache + node_modules so the gate's own `npm ci --offline` resolves. ---
RUN npm ci --legacy-peer-deps

# --- A throwaway git history (the judged tree carries no .git, D49.4/D49.5)
#     gives pre-commit and the forge-test hook a repo. The submodule content is
#     committed as plain files (fetch-submodules.sh stripped their nested .git),
#     so the forge-test hook's `git submodule update --init` finds no gitlinks
#     and is a no-op, and forge build/test use the committed lib/* files.
#     pre-commit install-hooks materializes every base hook's env offline.
#     install-hooks (not install) registers no git hook, so this build-time
#     commit fires none. The history is on a NON-main branch: the gate run's
#     `pre-commit run --all-files` runs reroute-main-commit, which refuses a
#     commit on main/master, so the throwaway branch must not be one. ---
RUN git init -q -b gate-tree \
    && git add -A \
    && git -c user.email=gate@armada-nitro -c user.name=gate \
           commit -qm "gate tree" \
    && pre-commit install-hooks --config .pre-commit-config.yaml

# No ENTRYPOINT: run_in_container passes the gate.command directly, and it runs
# in WORKDIR /gate with this image's PATH.
