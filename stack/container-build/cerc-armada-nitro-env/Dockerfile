# cerc/armada-nitro-env:local -- built with BuildKit (build.sh sets DOCKER_BUILDKIT=1).
#
# The build is split so a change to one upstream source's pin rebuilds only that
# source, and a byte change to env/sources.lock.json that does not change any pin
# rebuilds nothing:
#   - `toolchain`          the shared base (Debian + git/jq/python/just/foundry/node/yarn).
#   - `src-<name>`         one stage per env/sources.lock.json sources[] entry; its repo
#                          and commit come in as build ARGs (build.sh reads them from the
#                          lock with jq), so its layers are keyed only by that source's pin.
#   - `circuits`          Armada's pinned circuit build, keyed only by the armada-circuits
#                          ARGs (a lock file synthesised from them), never by lock bytes.
#   - `contracts`          this repo's Foundry inputs only + `forge build`, so env/ churn
#                          does not recompile contracts.
#   - final                copies each /src/<name>, merges the HOME caches the stages
#                          populated, the contracts build and the circuits, verifies pins.
#
# Build context: the repository root; .dockerignore excludes out/, cache/,
# broadcast/, deployments/ and any node_modules/.

# ============================ toolchain ====================================
FROM debian:bookworm AS toolchain

# Toolchain: git, jq, python3, curl, ca-certificates.
RUN set -e \
  && apt-get update \
  && apt-get install -y --no-install-recommends git jq python3 curl ca-certificates
# 'just' command runner (required by staking-modules/ repos).
RUN set -e \
  && curl -sL https://github.com/casey/just/releases/download/1.58.0/just-1.58.0-x86_64-unknown-linux-musl.tar.gz -o /tmp/just.tar.gz \
  && H=$(sha256sum /tmp/just.tar.gz) && test "${H%% *}" = "4a5cc2f53e6f0f8c59092a6cc38291eb729d46a7dd95d3ae582008881b84931d" \
  && tar xzf /tmp/just.tar.gz \
  && mv just /usr/local/bin/just \
  && chmod +x /usr/local/bin/just \
  && rm -f /tmp/just.tar.gz

# Home for root, so the foundryup bootstrap and the Foundry toolchain land in /root/.foundry/bin.
ENV HOME=/root

# Foundry toolchain via foundryup: pin v1.8.3.
RUN set -e \
  && curl -sL https://raw.githubusercontent.com/foundry-rs/foundryup/HEAD/foundryup-init.sh | bash
RUN set -e \
  && /root/.foundry/bin/foundryup -i v1.8.3

# Put the Foundry toolchain (forge, cast, anvil, chisel) on the default PATH.
ENV PATH=/root/.foundry/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Upstream projects pin solc 0.6/0.7; Foundry 1.8's dynamic test linking generates helpers
# those compilers reject. The image never runs upstream tests, so it is off everywhere.
ENV FOUNDRY_DYNAMIC_TEST_LINKING=false

# Node 22 LTS + corepack-enabled yarn 4.9.2.
RUN set -e \
  && curl -fsSL https://deb.nodesource.com/setup_22.x | bash
RUN set -e \
  && apt-get update \
  && apt-get install -y nodejs
RUN set -e \
  && corepack enable \
  && corepack prepare yarn@4.9.2 --activate

# The HOME caches the source stages populate (Yarn's global cache, svm-rs' solc
# store, hardhat's compilers). Created empty here so every `FROM toolchain` stage
# -- and the final image -- can `COPY --from` them uniformly, even from a stage
# that populated none of them.
RUN mkdir -p /root/.svm /root/.yarn/berry /root/.cache/hardhat-nodejs

# Generic clone step shared by every source stage.
COPY stack/container-build/cerc-armada-nitro-env/clone-source.sh /clone-source.sh
RUN chmod +x /clone-source.sh

# ============================ source stages ================================
# Each stage clones one env/sources.lock.json sources[] entry at its pinned
# commit (ARGs, asserted non-empty by clone-source.sh) and runs that project's
# own install/build. `forge build` fills /root/.svm; `yarn install` fills
# /root/.yarn/berry; `npx hardhat compile` fills /root/.cache/hardhat-nodejs.

# stablecoin-evm: CI=true makes its prepare script (setup.sh) exit before it
# invokes foundryup (the nightly), keeping forge at v1.8.3.
FROM toolchain AS src-stablecoin-evm
ARG SRC_STABLECOIN_EVM_REPO
ARG SRC_STABLECOIN_EVM_COMMIT
RUN /clone-source.sh "$SRC_STABLECOIN_EVM_REPO" "$SRC_STABLECOIN_EVM_COMMIT" stablecoin-evm
RUN cd /src/stablecoin-evm && CI=true yarn install --ignore-engines
RUN cd /src/stablecoin-evm && forge build

# evm-cctp-contracts: vendors OpenZeppelin via git submodule; forge build alone.
FROM toolchain AS src-evm-cctp-contracts
ARG SRC_EVM_CCTP_CONTRACTS_REPO
ARG SRC_EVM_CCTP_CONTRACTS_COMMIT
RUN /clone-source.sh "$SRC_EVM_CCTP_CONTRACTS_REPO" "$SRC_EVM_CCTP_CONTRACTS_COMMIT" evm-cctp-contracts
RUN cd /src/evm-cctp-contracts && forge build

# aave-v3-origin: vendors OpenZeppelin via git submodule; forge build alone.
FROM toolchain AS src-aave-v3-origin
ARG SRC_AAVE_V3_ORIGIN_REPO
ARG SRC_AAVE_V3_ORIGIN_COMMIT
RUN /clone-source.sh "$SRC_AAVE_V3_ORIGIN_REPO" "$SRC_AAVE_V3_ORIGIN_COMMIT" aave-v3-origin
RUN cd /src/aave-v3-origin && forge build

# lido-core: node_modules feeds foundry.toml's `libs`, so yarn install precedes forge build.
FROM toolchain AS src-lido-core
ARG SRC_LIDO_CORE_REPO
ARG SRC_LIDO_CORE_COMMIT
RUN /clone-source.sh "$SRC_LIDO_CORE_REPO" "$SRC_LIDO_CORE_COMMIT" lido-core
RUN cd /src/lido-core && yarn install --immutable
RUN cd /src/lido-core && forge build

# armada-poc: foundry.toml lists node_modules, so npm ci precedes forge build; it
# additionally needs `npx hardhat compile`.
FROM toolchain AS src-armada-poc
ARG SRC_ARMADA_POC_REPO
ARG SRC_ARMADA_POC_COMMIT
RUN /clone-source.sh "$SRC_ARMADA_POC_REPO" "$SRC_ARMADA_POC_COMMIT" armada-poc
RUN cd /src/armada-poc && npm ci
RUN cd /src/armada-poc && forge build
RUN cd /src/armada-poc && npx hardhat compile

# community-staking-module: yarn install + forge build, then the E12 slice 1
# offline setup. (a) `checkout -B develop` resets the stale develop branch (fetched
# at its old HEAD) onto the pinned commit, so lido's step-0135 `git clone -b develop`
# (redirected to the local copy by the final image's system git url.insteadOf) lands
# on the pin. (b) CSM vendors its own Yarn (.yarnrc.yml yarnPath) and leaves
# enableGlobalCache at its Yarn-4 default (true), so `just deps` populates
# /root/.yarn/berry/cache; running it once here, with network and HOME=/root fixed,
# lets a fresh clone's `just deps` at job time reuse those archives offline.
FROM toolchain AS src-community-staking-module
ARG SRC_COMMUNITY_STAKING_MODULE_REPO
ARG SRC_COMMUNITY_STAKING_MODULE_COMMIT
RUN /clone-source.sh "$SRC_COMMUNITY_STAKING_MODULE_REPO" "$SRC_COMMUNITY_STAKING_MODULE_COMMIT" community-staking-module
RUN cd /src/community-staking-module && yarn install --immutable
RUN cd /src/community-staking-module && forge build
RUN git -C /src/community-staking-module checkout -B develop
RUN cd /src/community-staking-module && just deps

# ============================ circuits =====================================
# Armada's circuit build (docs/tasks/E9-operability.md): fetched, verified and
# extracted once, here. Keyed ONLY by the armada-circuits pins (ARGs): a lock file
# is synthesised from them, and just the fetch code (env/reconciler/modules/
# _circuits.py + its imports) is copied, so a byte change elsewhere in
# env/sources.lock.json or the reconciler does not rebuild this stage. Jobs call
# the same module's verify() against the circuits baked in here -- never download.
FROM toolchain AS circuits
ARG ARMADA_CIRCUITS_REPO
ARG ARMADA_CIRCUITS_TAG
ARG ARMADA_CIRCUITS_TARBALL_SHA256
ARG ARMADA_CIRCUITS_SUMS_SHA256
RUN test -n "$ARMADA_CIRCUITS_REPO" && test -n "$ARMADA_CIRCUITS_TAG" \
  && test -n "$ARMADA_CIRCUITS_TARBALL_SHA256" && test -n "$ARMADA_CIRCUITS_SUMS_SHA256"
COPY env/reconciler/__init__.py /src/armada-nitro/env/reconciler/__init__.py
COPY env/reconciler/context.py /src/armada-nitro/env/reconciler/context.py
COPY env/reconciler/modules/__init__.py /src/armada-nitro/env/reconciler/modules/__init__.py
COPY env/reconciler/modules/_circuits.py /src/armada-nitro/env/reconciler/modules/_circuits.py
RUN jq -n \
      --arg repo "$ARMADA_CIRCUITS_REPO" \
      --arg tag "$ARMADA_CIRCUITS_TAG" \
      --arg tarball "$ARMADA_CIRCUITS_TARBALL_SHA256" \
      --arg sums "$ARMADA_CIRCUITS_SUMS_SHA256" \
      '{"armada-circuits":{"repo":$repo,"tag":$tag,"tarballSha256":$tarball,"sumsFileSha256":$sums}}' \
      > /src/armada-nitro/env/sources.lock.json
RUN set -e && cd /src/armada-nitro/env \
  && python3 -c "from reconciler.modules import _circuits; _circuits.fetch()"

# ============================ contracts ====================================
# This repository's contracts, compiled from only the Foundry inputs (remappings
# live in foundry.toml). Copying just these means env/ changes never recompile
# contracts. The output (out/, cache/) is copied into the final image.
FROM toolchain AS contracts
COPY foundry.toml foundry.lock /src/armada-nitro/
COPY src /src/armada-nitro/src
COPY script /src/armada-nitro/script
COPY test /src/armada-nitro/test
COPY lib /src/armada-nitro/lib
RUN set -e && cd /src/armada-nitro && forge build

# ============================ final image ==================================
FROM toolchain AS final

# Each upstream source tree, built in its own stage.
COPY --from=src-stablecoin-evm            /src/stablecoin-evm            /src/stablecoin-evm
COPY --from=src-evm-cctp-contracts        /src/evm-cctp-contracts        /src/evm-cctp-contracts
COPY --from=src-aave-v3-origin            /src/aave-v3-origin            /src/aave-v3-origin
COPY --from=src-lido-core                 /src/lido-core                 /src/lido-core
COPY --from=src-armada-poc                /src/armada-poc                /src/armada-poc
COPY --from=src-community-staking-module  /src/community-staking-module  /src/community-staking-module

# Merge the HOME caches the stages populated so jobs compile offline. These stores
# are content-addressed (solc by version, Yarn archives by hash, hardhat compilers
# by version), so overlaying one stage's copy onto the next simply unions them.
# svm-rs solc store: every forge-building stage + the contracts stage.
COPY --from=src-stablecoin-evm            /root/.svm/  /root/.svm/
COPY --from=src-evm-cctp-contracts        /root/.svm/  /root/.svm/
COPY --from=src-aave-v3-origin            /root/.svm/  /root/.svm/
COPY --from=src-lido-core                 /root/.svm/  /root/.svm/
COPY --from=src-armada-poc                /root/.svm/  /root/.svm/
COPY --from=src-community-staking-module  /root/.svm/  /root/.svm/
COPY --from=contracts                     /root/.svm/  /root/.svm/
# Yarn global cache: the yarn-installing stages (stablecoin-evm, lido-core, CSM).
COPY --from=src-stablecoin-evm            /root/.yarn/berry/  /root/.yarn/berry/
COPY --from=src-lido-core                 /root/.yarn/berry/  /root/.yarn/berry/
COPY --from=src-community-staking-module  /root/.yarn/berry/  /root/.yarn/berry/
# Corepack's downloaded package-manager binaries (the yarn CLI each project pins
# via its `packageManager` / .yarnrc.yml `yarnPath`). CSM pins yarn 4.1.1, which
# `just deps` re-launches from a fresh job-time clone: corepack must resolve it
# offline, so its download cache (populated when these stages ran with network)
# must be present. Content-addressed by version, so overlaying is a union.
COPY --from=src-stablecoin-evm            /root/.cache/node/corepack/  /root/.cache/node/corepack/
COPY --from=src-lido-core                 /root/.cache/node/corepack/  /root/.cache/node/corepack/
COPY --from=src-community-staking-module  /root/.cache/node/corepack/  /root/.cache/node/corepack/
# Hardhat compilers: armada-poc.
COPY --from=src-armada-poc                /root/.cache/hardhat-nodejs/  /root/.cache/hardhat-nodejs/

# System-wide git url.insteadOf so lido's step-0135 `git clone
# .../community-staking-module.git` resolves to the local copy -- no network at job time.
RUN git config --system "url.file:///src/community-staking-module.insteadOf" \
      "https://github.com/lidofinance/community-staking-module.git"

# This repository (env/, stack/, the real env/sources.lock.json, ...), then the
# contracts build output and the circuits on top.
COPY . /src/armada-nitro
COPY --from=contracts /src/armada-nitro/out   /src/armada-nitro/out
COPY --from=contracts /src/armada-nitro/cache /src/armada-nitro/cache
COPY --from=circuits  /src/armada-circuits    /src/armada-circuits

# Cheap check layer: every /src/<name> HEAD equals its pin in the real lock.
RUN bash -eu -c 'cd /src/armada-nitro \
  && while read -r name commit; do \
       have=$(git -C "/src/${name}" rev-parse HEAD); \
       [ "$have" = "$commit" ] || { echo "source ${name} at ${have}, expected ${commit}" >&2; exit 1; }; \
     done < <(jq -r ".sources[] | \"\(.name) \(.commit)\"" env/sources.lock.json)'

# Fail the build if the active Foundry version drifted from v1.8.3.
RUN forge --version | grep -q "Version: 1.8.3"
