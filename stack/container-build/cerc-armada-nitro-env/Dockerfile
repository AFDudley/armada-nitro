# Build context: the repository root; .dockerignore excludes out/, cache/, broadcast/
# and any node_modules/.
FROM debian:bookworm

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

# The lock file pins every upstream source to a commit; clone-sources.sh drives the
# checkout and per-project install/build.
COPY env/sources.lock.json /sources.lock.json
COPY stack/container-build/cerc-armada-nitro-env/clone-sources.sh /clone-sources.sh
RUN set -e \
  && chmod +x /clone-sources.sh \
  && /clone-sources.sh
# E12 slice 1: make lido's step-0135 CSM path work offline, without editing lido-core.
# (a) Point the local CSM repo's `develop` branch at the pinned commit. After
# clone-sources.sh the HEAD is detached at the pin, so `checkout -B develop`
# resets the stale `develop` branch (fetched at its old HEAD) onto the pin.
# (b) System-wide git `url.<local>.insteadOf` rewrite: lido's
# `git clone .../community-staking-module.git` now resolves to the local copy,
# so no network is needed at job time.
# (c) CSM vendors its own Yarn release (.yarnrc.yml's `yarnPath: .yarn/releases/
# yarn-4.1.1.cjs`, committed, so any clone of it carries it) and does not set
# `enableGlobalCache`, which defaults to true as of Yarn 4 (yarnpkg.com/
# configuration/yarnrc#enableGlobalCache): package archives land in
# `<globalFolder>/cache`, not the project's own `.yarn/cache` (gitignored
# there, so a fresh clone never carries it). `globalFolder` defaults to
# `$HOME/.yarn/berry`, and `HOME=/root` is fixed image-wide (line 20), so
# running `just deps` once now, with network, populates
# /root/.yarn/berry/cache in the image layer; a later `just deps` in a fresh
# clone (same lockfile, same HOME) reuses those cached archives instead of
# fetching them again.
RUN set -e \
  && git -C /src/community-staking-module checkout -B develop \
  && git config --system "url.file:///src/community-staking-module.insteadOf" \
       "https://github.com/lidofinance/community-staking-module.git" \
  && cd /src/community-staking-module && just deps


# This repository: copy to /src/armada-nitro, forge build.
COPY . /src/armada-nitro
RUN set -e && cd /src/armada-nitro && forge build

# Armada's circuit build (docs/tasks/E9-operability.md): fetched, verified, and
# extracted once, here, instead of by each job at run time. Pins (repo, release tag,
# tarball SHA-256, SHA256SUMS SHA-256) come from env/sources.lock.json's
# `armada-circuits` entry; a wrong pin fails this step, and so the image build. Jobs
# call the same module's verify() (env/reconciler/modules/_circuits.py) against the
# circuits baked in here -- they never download.
RUN set -e \
  && cd /src/armada-nitro/env \
  && python3 -c "from reconciler.modules import _circuits; _circuits.fetch()"

# Fail the build if the active Foundry version drifted from v1.8.3.
RUN forge --version | grep -q "Version: 1.8.3"
