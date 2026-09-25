# Build context: the repository root (with submodules checked out).
FROM ghcr.io/foundry-rs/foundry:v1.8.3

USER root
COPY stack/container-build/cerc-armada-nitro-foundry/armada-nitro-local /usr/local/bin/armada-nitro-local
RUN chmod 755 /usr/local/bin/armada-nitro-local
COPY --chown=foundry:foundry . /app
# Owned by foundry so the named volume mounted here is initialized writable.
RUN mkdir -p /app/deployments && chown foundry:foundry /app/deployments

USER foundry
WORKDIR /app
RUN forge build
