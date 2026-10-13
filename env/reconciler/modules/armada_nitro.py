"""armada_nitro module: deploy this repository's adjudicator, ConsensusApp and one hub
custodian against the Armada pool (script/Deploy.s.sol), and configure the custodian's
FROST group key from the target. See docs/ENVIRONMENT.md §6 (armada_nitro row) and
docs/tasks/E6-armada-and-nitro.md.
"""

from __future__ import annotations

import json

from typing import Any

from pathlib import Path
from reconciler.context import Context, resolve_target_mode, to_int
from reconciler.modules import _forge


def _read_group_key(ctx: Context) -> tuple[str, str]:
    """The FROST group public key (X, Y) from the frost-signer key file named by the
    target's `groupKeyFile` parameter. The file lives in the deployment's state directory
    (`ctx.state_dir`) and holds JSON `{"x": "0x<64hex>", "y": "0x<64hex>"}` (frost-signer's
    `group-pubkey.json`)."""
    params = resolve_target_mode(ctx.target["armada_nitro"])[1]
    key_file = Path(params["groupKeyFile"])
    path = key_file if key_file.is_absolute() else ctx.state_dir / key_file
    raw = json.loads(path.read_text())
    return raw["x"], raw["y"]


# env/reconciler/modules/armada_nitro.py -> repo root (this repository is baked into the
# image at /src/armada-nitro by `COPY . /src/armada-nitro`, so this resolves the same way
# whether run there or from a checked-out worktree).
_ARMADA_NITRO_ROOT = Path(__file__).resolve().parents[3]
_SCRIPT_TARGET = "script/Deploy.s.sol:Deploy"


def _uint(cast_output: str) -> int:
    # `cast call ...(uintN)` pretty-prints large values as "123 [1.23e5]".
    return to_int(cast_output.split()[0])


def observe(ctx: Context) -> dict[str, Any] | None:
    return ctx.manifest.get("armadaNitro")


def apply(ctx: Context, observed: dict[str, Any] | None) -> tuple[str, int]:
    mode, params = resolve_target_mode(ctx.target["armada_nitro"])

    if mode == "adopt":
        adjudicator = params["adjudicator"]
        action = "present" if observed and observed.get("adjudicator") == adjudicator else "adopted"
        ctx.manifest["armadaNitro"] = {
            "adjudicator": adjudicator,
            "consensusApp": params["consensusApp"],
            "hubCustodian": params["hubCustodian"],
        }
        return action, 0

    # mode == "deploy": an adjudicator already on record is never redeployed, but the group
    # key is still (re)recorded in the manifest so the deployment state shows the key actually
    # deployed.
    if observed and observed.get("adjudicator"):
        group_key_x, group_key_y = _read_group_key(ctx)
        observed["groupKeyX"] = group_key_x
        observed["groupKeyY"] = group_key_y
        return "present", 0

    armada = ctx.manifest.get("armada")
    if not armada or not armada.get("pool"):
        raise ctx.fail("armada module has not been reconciled; run it before armada_nitro (MODULE_ORDER)")

    # arn-3d8: the adjudicator only funds assets on its configured list. The fixturenet's hub
    # list is USDC, WETH, wstETH, waUSDC, each already recorded by an earlier module
    # (MODULE_ORDER: weth, usdc, cctp, aave, lido, armada all run before armada_nitro).
    assets = ctx.manifest.get("assets", {})
    configured_assets = [armada["usdc"]]
    for key in ("weth", "wstETH", "waUSDC"):
        address = assets.get(key)
        if not address:
            raise ctx.fail(
                f"assets.{key} has not been reconciled; run its module before armada_nitro (MODULE_ORDER)"
            )
        configured_assets.append(address)

    group_key_x, group_key_y = _read_group_key(ctx)
    chain_id = ctx.target["network"]["chainId"]

    # Deploy.s.sol writes deployments/<chainId>.json (vm.writeJson) but -- unlike the
    # broadcast artifact directory forge itself creates -- never creates this directory;
    # .gitignore's "/deployments/31337*" confirms it is meant to exist at runtime, not be
    # checked in. Without it vm.writeJson reverts *after* the broadcast already landed on
    # chain, and forge then refuses to write the broadcast artifact this module reads.
    (_ARMADA_NITRO_ROOT / "deployments").mkdir(parents=True, exist_ok=True)

    receipts = _forge.run_broadcast(
        project_dir=_ARMADA_NITRO_ROOT,
        script_target=_SCRIPT_TARGET,
        rpc_url=ctx.rpc_url,
        chain_id=chain_id,
        env={
            "ARMADA_POOL": armada["pool"],
            "HUB_GROUP_KEY_X": group_key_x,
            "HUB_GROUP_KEY_Y": group_key_y,
            "HUB_REVOCATION_DELAY": str(params["revocationDelay"]),
            "ARMADA_ASSETS": ",".join(configured_assets),
        },
        extra_args=("--private-keys", ctx.deployer_key),
    )
    gas_used = _forge.sum_gas_used(receipts)

    # Deploy.s.sol's `new X()` and `vm.deployCode(...)` (for HubCustodian) are each a
    # top-level broadcast CREATE, so all three are plain created_contract_address lookups
    # (verified against this script's own broadcast artifact; none show up nested under
    # additionalContracts the way CCTP's CREATE2-factory-deployed proxies do in cctp.py).
    adjudicator = _forge.created_contract_address(receipts, "ArmadaNitroAdjudicator")
    consensus_app = _forge.created_contract_address(receipts, "ConsensusApp")
    custodian = _forge.created_contract_address(receipts, "HubCustodian")

    ctx.manifest["armadaNitro"] = {
        "adjudicator": adjudicator,
        "consensusApp": consensus_app,
        "hubCustodian": custodian,
        "groupKeyFile": params["groupKeyFile"],
        "groupKeyX": group_key_x,
        "groupKeyY": group_key_y,
    }
    ctx.manifest.setdefault("gasUsed", {})
    ctx.manifest["gasUsed"]["armada_nitro"] = ctx.manifest["gasUsed"].get("armada_nitro", 0) + gas_used
    return "deployed", gas_used


def verify(ctx: Context, action: str) -> None:
    armada_nitro = ctx.manifest.get("armadaNitro")
    if not armada_nitro:
        raise ctx.fail("no armadaNitro recorded; run without --verify-only first")
    adjudicator = armada_nitro["adjudicator"]
    custodian = armada_nitro["hubCustodian"]

    armada = ctx.manifest.get("armada")
    if not armada or not armada.get("pool"):
        raise ctx.fail("no armada.pool recorded; run the armada module first")
    pool = ctx.cast("call", adjudicator, "pool()(address)")
    if pool.lower() != armada["pool"].lower():
        raise ctx.fail(f"adjudicator.pool() = {pool}, expected {armada['pool']}")

    mode, params = resolve_target_mode(ctx.target["armada_nitro"])
    if mode == "deploy":
        expected_x, expected_y = _read_group_key(ctx)
        group_key_x = _uint(ctx.cast("call", custodian, "groupKeyX()(uint256)"))
        group_key_y = _uint(ctx.cast("call", custodian, "groupKeyY()(uint256)"))
        if group_key_x != int(expected_x, 16):
            raise ctx.fail(f"custodian.groupKeyX() = {group_key_x}, expected {int(expected_x, 16)}")
        if group_key_y != int(expected_y, 16):
            raise ctx.fail(f"custodian.groupKeyY() = {group_key_y}, expected {int(expected_y, 16)}")
        if "revocationDelay" in params:
            revocation_delay = _uint(ctx.cast("call", custodian, "revocationDelay()(uint256)"))
            if revocation_delay != int(params["revocationDelay"]):
                raise ctx.fail(
                    f"custodian.revocationDelay() = {revocation_delay}, expected {params['revocationDelay']}"
                )
    else:
        # Adopt: group-key coordinates and revocation delay are optional fields,
        # carried through by tools/adopt_target.py only when the manifest records
        # them. A manifest that recorded just the three custodian addresses is still
        # valid input.
        if "groupKeyX" in params and "groupKeyY" in params:
            group_key_x = _uint(ctx.cast("call", custodian, "groupKeyX()(uint256)"))
            group_key_y = _uint(ctx.cast("call", custodian, "groupKeyY()(uint256)"))
            if group_key_x != int(params["groupKeyX"], 16):
                raise ctx.fail(
                    f"custodian.groupKeyX() = {group_key_x}, expected {int(params['groupKeyX'], 16)}"
                )
            if group_key_y != int(params["groupKeyY"], 16):
                raise ctx.fail(
                    f"custodian.groupKeyY() = {group_key_y}, expected {int(params['groupKeyY'], 16)}"
                )
        if "revocationDelay" in params:
            revocation_delay = _uint(ctx.cast("call", custodian, "revocationDelay()(uint256)"))
            if revocation_delay != int(params["revocationDelay"]):
                raise ctx.fail(
                    f"custodian.revocationDelay() = {revocation_delay}, expected {params['revocationDelay']}"
                )
