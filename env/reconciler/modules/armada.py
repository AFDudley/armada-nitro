"""armada module: deploy Armada's own PrivacyPool (hub only) at the demo3 commit
(lib/armada-poc, 532bc064) over this environment's USDC and CCTP v2, using Armada's
own `scripts/deploy_privacy_pool.ts --network hub`. See docs/ENVIRONMENT.md §6 (armada
row) and docs/tasks/E6-armada-and-nitro.md.

Two things this script needs that the brief's env-var list alone does not supply, found
by reading it (not a wrong brief fact -- the brief's env vars are still exactly what
drives both, they just don't reach `deployHub()` the way one might expect):

1. `deployHub()` never reads HUB_USDC/CCTP_TOKEN_MESSENGER/CCTP_MESSAGE_TRANSMITTER
   itself. It loads `deployments/hub-v3.json` (`getCCTPDeploymentFile("hub")`) and takes
   the CCTP addresses from there, failing with "Run deploy_cctp first" if the file is
   absent. `scripts/deploy_cctp_sepolia.ts` is the (misleadingly named -- it keys off
   `getChainRole(chainId)`, not the hardhat network name, and only requires
   `CCTP_MODE=real`) script that writes that file from exactly the env vars the brief
   names, after verifying each address has code on-chain and that USDC has 6 decimals.
   It sends no transactions. This module runs it immediately before
   `deploy_privacy_pool.ts`, both with the same environment.

2. `loadVerificationKeys` (step 9) needs Armada's own compiled circuit artifacts on
   disk (`lib/sdk/armada-artifacts.ts`, fixed path `/src/armada-circuits/build/<n>x<m>/`).
   Upstream fetches those with `scripts/fetch-circuits.sh`, which shells out to the `gh`
   CLI, not present in this image. Here they are baked into the image at build time
   (stack/container-build/cerc-armada-nitro-env/Dockerfile, `_circuits.fetch()`) from
   the same repo/tag/SHA-256 pins as fetch-circuits.sh, now recorded once in
   env/sources.lock.json's `armada-circuits` entry. `_ensure_circuits_fetched` below
   only verifies those baked-in circuits (`_circuits.verify()`) -- it never downloads at
   job time (docs/tasks/E9-operability.md). The container filesystem is discarded after
   the job, so this re-verifies every time apply() actually deploys -- but that is only
   ever the first run, and verifying is a local SHA-256 pass, not a network fetch.
"""

from __future__ import annotations

from typing import Any

import hashlib
import json
import os
import subprocess
from pathlib import Path

from reconciler.context import CastError, Context, resolve_target_mode, to_int
from reconciler.modules import _circuits, _wallet

_ARMADA_POC = Path("/src/armada-poc")
_HUB_POOL_DEPLOYMENT_FILE = _ARMADA_POC / "deployments" / "privacy-pool-hub.json"
_HUB_CCTP_DEPLOYMENT_FILE = _ARMADA_POC / "deployments" / "hub-v3.json"

# anvil account 7 (test test ... junk, index 7): the fixturenet's treasury (Deploy env
# TREASURY_ADDRESS), per docs/tasks/E6-armada-and-nitro.md.
_TREASURY_ACCOUNT_INDEX = 7

# Recorded in the manifest verbatim (docs/ENVIRONMENT.md §5); this is the base URL a
# runtime SDK later fetches circuits from, not where this module gets them (see
# _ensure_circuits_fetched / reconciler.modules._circuits).
_ARTIFACTS_BASE_URL = "https://circuits.knowable.run/v0.1.0-dev"

# The demo3 pool on Sepolia this environment's verification keys must match
# (docs/ENVIRONMENT.md §6; verified reachable by the integrator, see the task brief).
_SEPOLIA_RPC = "https://ethereum-sepolia-rpc.publicnode.com"
_SEPOLIA_POOL = "0x5f3324b47b3CFf937BB67C30B362898E193e5216"

# lib/armada-poc/lib/artifacts.ts TESTING_ARTIFACT_CONFIGS, copied verbatim (19 shapes)
# -- this is the exact set deploy_privacy_pool.ts registers on the pool, so it is also
# the exact set this module must compare against Sepolia's demo3 pool.
_TESTING_ARTIFACT_CONFIGS: list[tuple[int, int]] = [
    (1, 1),
    (1, 2),
    (2, 2),
    (2, 3),
    (8, 4),
    (2, 1),
    (3, 1),
    (4, 1),
    (5, 1),
    (6, 1),
    (7, 1),
    (8, 1),
    (3, 2),
    (4, 2),
    (5, 2),
    (6, 2),
    (1, 3),
    (3, 3),
    (4, 3),
]


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _ensure_circuits_fetched() -> None:
    """The circuits are baked into the image (see module docstring point 2); this only
    verifies them, and never downloads at job time."""
    _circuits.verify()


def _run_hardhat(script: str, env: dict[str, str]) -> str:
    full_env = {**os.environ, **env}
    result = subprocess.run(
        ["npx", "hardhat", "run", script, "--network", "hub"],
        capture_output=True,
        text=True,
        cwd=str(_ARMADA_POC),
        env=full_env,
    )
    if result.returncode != 0:
        raise CastError(
            f"hardhat run {script} failed (exit {result.returncode}): {result.stderr.strip()[-4000:]}"
        )
    return result.stdout


def _gas_used_since(ctx: Context, start_block: int) -> tuple[int, int]:
    """Sum every block's total gasUsed from `start_block + 1` through the current head.
    Safe because this module's apply() is the only code sending transactions while it
    runs (weth/usdc/cctp already reconciled; armada_nitro/funding run after)."""
    end_block = to_int(ctx.cast("block-number"))
    total = 0
    for block_number in range(start_block + 1, end_block + 1):
        block = json.loads(ctx.cast("rpc", "eth_getBlockByNumber", hex(block_number), "false"))
        total += to_int(block["gasUsed"])
    return total, end_block


def observe(ctx: Context) -> dict[str, Any] | None:
    return ctx.manifest.get("armada")


def apply(ctx: Context, observed: dict[str, Any] | None) -> tuple[str, int]:
    mode, params = resolve_target_mode(ctx.target["armada"])

    if mode == "adopt":
        pool = params["pool"]
        action = "present" if observed and observed.get("pool") == pool else "adopted"
        ctx.manifest["armada"] = {
            "pool": pool,
            "usdc": params["usdc"],
            "deployBlock": params["deployBlock"],
            "artifactsBaseUrl": _ARTIFACTS_BASE_URL,
        }
        return action, 0

    # mode == "deploy": a pool already on record is never redeployed.
    if observed and observed.get("pool"):
        return "present", 0

    usdc = ctx.manifest.get("usdc")
    cctp = ctx.manifest.get("cctp")
    if not usdc or not usdc.get("proxy") or not cctp or not cctp.get("tokenMessenger"):
        raise ctx.fail("usdc/cctp modules have not been reconciled; run them before armada (MODULE_ORDER)")

    _ensure_circuits_fetched()

    treasury = _wallet.address(_TREASURY_ACCOUNT_INDEX)
    env = {
        "HUB_RPC": ctx.rpc_url,
        "DEPLOY_ENV": "local",
        "CCTP_MODE": "real",
        "HUB_USDC": usdc["proxy"],
        "CCTP_TOKEN_MESSENGER": cctp["tokenMessenger"],
        "CCTP_MESSAGE_TRANSMITTER": cctp["messageTransmitter"],
        "CCTP_TOKEN_MINTER": cctp["tokenMinter"],
        "HUB_CCTP_DOMAIN": str(cctp["domain"]),
        "TREASURY_ADDRESS": treasury,
    }

    start_block = to_int(ctx.cast("block-number"))

    # See module docstring point 1: writes deployments/hub-v3.json; sends no transactions.
    _run_hardhat("scripts/deploy_cctp_sepolia.ts", env)
    _run_hardhat("scripts/deploy_privacy_pool.ts", env)

    gas_used, _ = _gas_used_since(ctx, start_block)

    deployment = json.loads(_HUB_POOL_DEPLOYMENT_FILE.read_text())
    pool = deployment["contracts"]["privacyPool"]
    deployed_usdc = deployment["cctp"]["usdc"]
    if deployed_usdc.lower() != usdc["proxy"].lower():
        raise ctx.fail(
            f"deployed pool's usdc = {deployed_usdc}, expected manifest usdc.proxy {usdc['proxy']}"
        )

    # Copy what's needed into the reconciler state dir -- the container filesystem
    # (including /src/armada-poc/deployments) is discarded once the job exits.
    state_deployments = ctx.state_dir / "armada-deployments"
    state_deployments.mkdir(parents=True, exist_ok=True)
    (state_deployments / "privacy-pool-hub.json").write_text(_HUB_POOL_DEPLOYMENT_FILE.read_text())
    (state_deployments / "hub-v3.json").write_text(_HUB_CCTP_DEPLOYMENT_FILE.read_text())

    ctx.manifest["armada"] = {
        "pool": pool,
        "usdc": deployed_usdc,
        "deployBlock": deployment["deployBlock"],
        "artifactsBaseUrl": _ARTIFACTS_BASE_URL,
    }
    ctx.manifest.setdefault("gasUsed", {})
    ctx.manifest["gasUsed"]["armada"] = ctx.manifest["gasUsed"].get("armada", 0) + gas_used
    return "deployed", gas_used


def verify(ctx: Context, action: str) -> None:
    armada = ctx.manifest.get("armada")
    if not armada:
        raise ctx.fail("no armada recorded; run without --verify-only first")
    pool = armada["pool"]

    testing_mode = ctx.cast("call", pool, "testingMode()(bool)")
    if testing_mode != "false":
        raise ctx.fail(f"testingMode() = {testing_mode}, expected false")

    pool_usdc = ctx.cast("call", pool, "usdc()(address)")
    if pool_usdc.lower() != armada["usdc"].lower():
        raise ctx.fail(f"pool.usdc() = {pool_usdc}, expected {armada['usdc']}")

    cctp = ctx.manifest.get("cctp")
    if not cctp:
        raise ctx.fail("no cctp recorded; run the cctp module first")
    pool_token_messenger = ctx.cast("call", pool, "tokenMessenger()(address)")
    if pool_token_messenger.lower() != cctp["tokenMessenger"].lower():
        raise ctx.fail(f"pool.tokenMessenger() = {pool_token_messenger}, expected {cctp['tokenMessenger']}")
    pool_message_transmitter = ctx.cast("call", pool, "messageTransmitter()(address)")
    if pool_message_transmitter.lower() != cctp["messageTransmitter"].lower():
        raise ctx.fail(
            f"pool.messageTransmitter() = {pool_message_transmitter}, expected {cctp['messageTransmitter']}"
        )

    mismatches = []
    for nullifiers, commitments in _TESTING_ARTIFACT_CONFIGS:
        fixturenet_vk = ctx.cast(
            "call", pool, "getVerificationKey(uint256,uint256)", str(nullifiers), str(commitments)
        )
        sepolia_vk = ctx.cast(
            "call",
            _SEPOLIA_POOL,
            "getVerificationKey(uint256,uint256)",
            str(nullifiers),
            str(commitments),
            rpc_url=_SEPOLIA_RPC,
        )
        equal = fixturenet_vk.lower() == sepolia_vk.lower()
        fixturenet_hash = hashlib.sha256(bytes.fromhex(fixturenet_vk[2:])).hexdigest()
        sepolia_hash = hashlib.sha256(bytes.fromhex(sepolia_vk[2:])).hexdigest()
        print(
            f"armada vk ({nullifiers},{commitments}): fixturenet={fixturenet_hash} "
            f"sepolia={sepolia_hash} {'EQUAL' if equal else 'MISMATCH'}"
        )
        if not equal:
            mismatches.append((nullifiers, commitments))
    if mismatches:
        raise ctx.fail(f"verification keys differ from Sepolia demo3 pool for shapes: {mismatches}")
