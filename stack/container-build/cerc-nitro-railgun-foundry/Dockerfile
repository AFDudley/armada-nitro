# Build context: the repository root (with submodules checked out).
FROM ghcr.io/foundry-rs/foundry:v1.8.3

USER root
COPY stack/container-build/cerc-nitro-railgun-foundry/nitro-railgun-local /usr/local/bin/nitro-railgun-local
RUN chmod 755 /usr/local/bin/nitro-railgun-local
COPY --chown=foundry:foundry . /app
# Owned by foundry so the named volume mounted here is initialized writable.
RUN mkdir -p /app/deployments && chown foundry:foundry /app/deployments

USER foundry
WORKDIR /app
RUN forge build
