#!/usr/bin/env bash
# Clone each upstream source pinned in /sources.lock.json into /src/<name> at its
# commit (with submodules), then install dependencies and build as each project
# documents:
#   - stablecoin-evm and lido-core need `node_modules` populated before `forge build`
#     (their foundry.toml `libs` includes `node_modules`), so `yarn install` runs first.
#   - armada-poc's foundry.toml also lists `node_modules`, so `npm ci` runs before
#     `forge build`; it additionally needs `npx hardhat compile`.
#   - evm-cctp-contracts and aave-v3-origin vendor OpenZeppelin via git submodules only,
#     so `forge build` alone succeeds once submodules are checked out.
set -e
cd /

while IFS="|" read -r name repo ref commit; do
  url="https://github.com/${repo}"
  git clone --depth 1 "${url}" "/src/${name}"
  git -C "/src/${name}" fetch --depth 1 origin "${commit}"
  git -C "/src/${name}" checkout "${commit}"
  git -C "/src/${name}" submodule update --init --recursive
  case "${name}" in
    stablecoin-evm)
      # CI=true makes the stablecoin-evm prepare script (setup.sh) exit early before it invokes foundryup (the nightly), keeping forge at v1.8.3.
      (cd "/src/${name}" && CI=true yarn install --ignore-engines)
      ;;
    lido-core)
      (cd "/src/${name}" && yarn install --immutable)
      ;;
    armada-poc)
      (cd "/src/${name}" && npm ci)
      ;;
  esac
  if [ -f "/src/${name}/foundry.toml" ]; then
    (cd "/src/${name}" && forge build)
  fi
  if [ "${name}" = "armada-poc" ]; then
    (cd "/src/${name}" && npx hardhat compile)
  fi
done < <(jq -r '.sources[] | "\(.name)|\(.repo)|\(.ref)|\(.commit)"' /sources.lock.json)

# Fail unless every pinned source is checked out at its commit (an empty loop must not pass).
while read -r name commit; do
  [ "$(git -C "/src/${name}" rev-parse HEAD 2>/dev/null)" = "${commit}" ] \
    || { echo "source ${name} is not at ${commit}" >&2; exit 1; }
done < <(jq -r '.sources[] | "\(.name) \(.commit)"' /sources.lock.json)
