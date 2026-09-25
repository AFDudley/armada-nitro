# Build context: the repository root; .dockerignore excludes out/, cache/, broadcast/
# and any node_modules/.
FROM debian:bookworm

# Toolchain: git, jq, python3, curl, ca-certificates.
RUN set -e \
  && apt-get update \
  && apt-get install -y --no-install-recommends git jq python3 curl ca-certificates

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

# This repository: copy to /src/armada-nitro, forge build.
COPY . /src/armada-nitro
RUN set -e && cd /src/armada-nitro && forge build

# Fail the build if the active Foundry version drifted from v1.8.3.
RUN forge --version | grep -q "Version: 1.8.3"
