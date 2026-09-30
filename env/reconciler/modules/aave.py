"""aave module: deploy this environment's Aave v3 market (env/aave/EnvMarketInput.sol +
env/aave/script/DeployMarket.s.sol, driving aave-v3-origin's own
`AaveV3BatchOrchestration.deployAaveV3` -- see env/aave/EnvMarketInput.sol's docstring for why
this is not a literal `is MarketInput`), the fixturenet's USDC `MockAggregator` price feed,
list USDC through `AaveV3ConfigEngine.listAssets` at mainnet's USDC reserve parameters
(env/aave/mainnet-usdc-reserve.json, env/aave/EnvUsdcListingPayload.sol), and create the
`waUSDC` stata token (`StataTokenFactory.createStataTokens`). See docs/ENVIRONMENT.md §6
(aave row) and docs/tasks/E4-aave.md.
"""

from __future__ import annotations

from typing import Any, cast

import json
from pathlib import Path

from reconciler.context import Context, resolve_target_mode, to_int
from reconciler.modules import _forge

# env/reconciler/modules/aave.py -> env/aave (two directories up, then into aave/).
_ENV_AAVE = Path(__file__).resolve().parents[2] / "aave"
_RESERVE_JSON = _ENV_AAVE / "mainnet-usdc-reserve.json"
_SCRIPT_TARGET = "script/DeployMarket.s.sol:DeployMarket"
_REPORT_FILE = _ENV_AAVE / "reports" / "aave-market.json"

# One-time stata-token round-trip proof (docs/ENVIRONMENT.md §6: "Depositing 100 USDC into
# the stata token and redeeming every share returns 100 USDC at index 1").
_DEPOSIT_AMOUNT = 100_000_000  # 100 USDC at 6 decimals
_MINTER_ALLOWANCE = 1_000_000_000_000  # 1,000,000 USDC; mirrors funding.py's headroom

# Actions that prove correctness by live transactions (the deposit/redeem round-trip), not
# just by reading state. Re-running that proof on an already-reconciled module would break
# idempotency, so it runs once, the first time this run recognizes the pool. Mirrors
# weth.py/usdc.py's _FRESHLY_RECOGNIZED.
_FRESHLY_RECOGNIZED = ("deployed", "adopted")

# ReserveConfiguration.sol bit layout (/src/aave-v3-origin, tag v3.7.0,
# src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol) -- (field name,
# start bit, bit length). Field names match env/aave/mainnet-usdc-reserve.json's
# reserveConfiguration keys exactly.
_CONFIG_FIELDS = [
    ("ltv", 0, 16),
    ("liquidationThreshold", 16, 16),
    ("liquidationBonus", 32, 16),
    ("decimals", 48, 8),
    ("active", 56, 1),
    ("frozen", 57, 1),
    ("borrowingEnabled", 58, 1),
    ("paused", 60, 1),
    ("flashloanEnabled", 63, 1),
    ("reserveFactor", 64, 16),
    ("borrowCap", 80, 36),
    ("supplyCap", 116, 36),
    ("liquidationProtocolFee", 152, 16),
    ("virtualAccountingActive", 252, 1),
]

# Fields a difference in is a §6 postcondition failure verbatim (docs/tasks/E4-aave.md:
# "A difference in LTV, liquidation threshold, liquidation bonus, decimals or reserve factor
# is a failure"). Every other decoded field is printed for the "explain any bit that differs"
# ask, but not gated.
_GATED_FIELDS = ("ltv", "liquidationThreshold", "liquidationBonus", "decimals", "reserveFactor")


def _uint(cast_output: str) -> int:
    # `cast call ...(uintN)` pretty-prints large values as "1000000 [1e6]".
    return to_int(cast_output.split()[0])


def _decode_configuration(raw: int) -> dict[str, Any]:
    decoded: dict[str, Any] = {}
    for name, start, length in _CONFIG_FIELDS:
        value = (raw >> start) & ((1 << length) - 1)
        decoded[name] = bool(value) if length == 1 else value
    return decoded


def _reserve_data(ctx: Context, pool: str, asset: str) -> dict[str, Any]:
    # DataTypes.ReserveDataLegacy (IPool.getReserveData): the first field is the
    # single-uint256-field ReserveConfigurationMap struct, hence the nested `(uint256)`.
    sig = (
        "getReserveData(address)((uint256),uint128,uint128,uint128,uint128,uint128,"
        "uint40,uint16,address,address,address,address,uint128,uint128,uint128)"
    )
    lines = ctx.cast("call", pool, sig, asset).splitlines()
    # The struct-of-a-single-uint256 ReserveConfigurationMap prints as its own parenthesized
    # tuple on this line, e.g. "(7237...420 [7.237e75])" -- strip the wrapping paren cast adds
    # for a nested tuple before the shared _uint() annotation-stripping split.
    configuration = _uint(lines[0].lstrip("("))
    return {"configuration": configuration, "aTokenAddress": lines[8].strip()}


def _reserve_target() -> dict[str, Any]:
    return cast("dict[str, Any]", json.loads(_RESERVE_JSON.read_text()))


def observe(ctx: Context) -> dict[str, Any] | None:
    return ctx.manifest.get("aave")


def apply(ctx: Context, observed: dict[str, Any] | None) -> tuple[str, int]:
    mode, params = resolve_target_mode(ctx.target["aave"])

    if mode == "adopt":
        pool = params["pool"]
        action = "present" if observed and observed.get("pool") == pool else "adopted"
        ctx.manifest["aave"] = {
            "poolAddressesProvider": params["poolAddressesProvider"],
            "pool": pool,
            "aUSDC": params["aUSDC"],
            "stataTokenFactory": params["stataTokenFactory"],
            "usdcPriceFeed": params["usdcPriceFeed"],
        }
        ctx.manifest.setdefault("assets", {})["waUSDC"] = params["waUSDC"]
        return action, 0

    # mode == "deploy": a pool already on record is never redeployed.
    if observed and observed.get("pool"):
        return "present", 0

    weth = ctx.manifest.get("assets", {}).get("weth")
    usdc = ctx.manifest.get("usdc", {}).get("proxy")
    if not weth or not usdc:
        raise ctx.fail("weth/usdc modules have not been reconciled; run them before aave (MODULE_ORDER)")

    reserve = _reserve_target()
    cfg = reserve["reserveConfiguration"]
    rate = reserve["interestRateStrategy"]
    chain_id = ctx.target["network"]["chainId"]

    # AaveV3ConfigEngine.Listing.liqBonus is the bonus *delta* above 100%, not the raw
    # on-chain liquidationBonus: CollateralEngine.sol passes `poolConfigurator
    # .configureReserveAsCollateral(asset, ltv, liqThreshold, 100_00 + updates[i].liqBonus)`
    # (src/contracts/extensions/v3-config-engine/libraries/CollateralEngine.sol in
    # /src/aave-v3-origin, tag v3.7.0) -- passing the raw mainnet value (10450, i.e. already
    # including the 100_00 base) here makes the engine compute an effective liqBonus of
    # 204.50% and its own "LT*LB <= 100%" sanity check (INVALID_LT_LB_RATIO) revert.
    # Confirmed by reproduction: the fixturenet deploy failed with exactly that revert
    # before this subtraction was added.
    liq_bonus_delta = cfg["liquidationBonus"] - 100_00

    # script/DeployMarket.s.sol's `vm.writeJson` does not create missing parent directories
    # (mirrors armada_nitro.py's `deployments/`.mkdir workaround for Deploy.s.sol).
    _REPORT_FILE.parent.mkdir(parents=True, exist_ok=True)
    if _REPORT_FILE.exists():
        _REPORT_FILE.unlink()

    env = {
        "AAVE_WRAPPED_NATIVE_TOKEN": weth,
        "AAVE_USDC": usdc,
        "AAVE_USDC_LTV": str(cfg["ltv"]),
        "AAVE_USDC_LIQ_THRESHOLD": str(cfg["liquidationThreshold"]),
        "AAVE_USDC_LIQ_BONUS": str(liq_bonus_delta),
        "AAVE_USDC_RESERVE_FACTOR": str(cfg["reserveFactor"]),
        "AAVE_USDC_LIQ_PROTOCOL_FEE": str(cfg["liquidationProtocolFee"]),
        "AAVE_USDC_SUPPLY_CAP": str(cfg["supplyCap"]),
        "AAVE_USDC_BORROW_CAP": str(cfg["borrowCap"]),
        "AAVE_USDC_OPTIMAL_USAGE_RATIO": str(rate["optimalUsageRatio"]),
        "AAVE_USDC_BASE_VARIABLE_BORROW_RATE": str(rate["baseVariableBorrowRate"]),
        "AAVE_USDC_VARIABLE_RATE_SLOPE1": str(rate["variableRateSlope1"]),
        "AAVE_USDC_VARIABLE_RATE_SLOPE2": str(rate["variableRateSlope2"]),
    }

    receipts = _forge.run_broadcast(
        project_dir=_ENV_AAVE,
        script_target=_SCRIPT_TARGET,
        rpc_url=ctx.rpc_url,
        chain_id=chain_id,
        env=env,
        extra_args=("--private-keys", ctx.deployer_key),
    )
    gas_used = _forge.sum_gas_used(receipts)

    if not _REPORT_FILE.exists():
        raise ctx.fail(f"script/DeployMarket.s.sol did not write {_REPORT_FILE}")
    output = json.loads(_REPORT_FILE.read_text())

    ctx.manifest["aave"] = {
        "poolAddressesProvider": output["poolAddressesProvider"],
        "pool": output["pool"],
        "aUSDC": output["aUSDC"],
        "stataTokenFactory": output["stataTokenFactory"],
        "usdcPriceFeed": output["usdcPriceFeed"],
    }
    ctx.manifest.setdefault("assets", {})["waUSDC"] = output["waUSDC"]
    ctx.manifest.setdefault("gasUsed", {})
    ctx.manifest["gasUsed"]["aave"] = ctx.manifest["gasUsed"].get("aave", 0) + gas_used
    return "deployed", gas_used


def verify(ctx: Context, action: str) -> None:
    aave = ctx.manifest.get("aave")
    if not aave:
        raise ctx.fail("no aave recorded; run without --verify-only first")
    wa_usdc = ctx.manifest.get("assets", {}).get("waUSDC")
    if not wa_usdc:
        raise ctx.fail("no assets.waUSDC recorded; run without --verify-only first")

    usdc_manifest = ctx.manifest.get("usdc")
    if not usdc_manifest or not usdc_manifest.get("proxy"):
        raise ctx.fail("no usdc recorded; run the usdc module first")
    pool = aave["pool"]
    usdc = usdc_manifest["proxy"]

    reserve_data = _reserve_data(ctx, pool, usdc)
    a_usdc = reserve_data["aTokenAddress"]
    if int(a_usdc, 16) == 0:
        raise ctx.fail("getReserveData(usdc).aTokenAddress = 0x0")
    if a_usdc.lower() != aave["aUSDC"].lower():
        raise ctx.fail(
            f"getReserveData(usdc).aTokenAddress = {a_usdc}, manifest aave.aUSDC = {aave['aUSDC']}"
        )

    fixturenet_cfg = _decode_configuration(reserve_data["configuration"])
    mainnet_cfg = _reserve_target()["reserveConfiguration"]

    mismatches = []
    for name in _GATED_FIELDS:
        if fixturenet_cfg[name] != mainnet_cfg[name]:
            mismatches.append(f"{name}: fixturenet={fixturenet_cfg[name]} mainnet={mainnet_cfg[name]}")
    if mismatches:
        raise ctx.fail("reserve configuration differs from mainnet's USDC reserve: " + "; ".join(mismatches))

    # Every other decoded bit: informational only (docs/tasks/E4-aave.md: "Explain any bit of
    # the two configuration words that differs"). This environment's listing
    # (env/aave/EnvUsdcListingPayload.sol) deliberately mirrors mainnet's borrowing/flashloan/
    # cap/fee bits too, so a printed difference here flags something about the listing, not
    # just this postcondition.
    for name, _, _ in _CONFIG_FIELDS:
        if name in _GATED_FIELDS:
            continue
        fixturenet_value, mainnet_value = fixturenet_cfg[name], mainnet_cfg[name]
        status = "matches" if fixturenet_value == mainnet_value else "DIFFERS"
        print(
            f"aave reserve configuration bit '{name}' {status}: fixturenet={fixturenet_value} mainnet={mainnet_value}"
        )

    stata_asset = ctx.cast("call", wa_usdc, "asset()(address)")
    if stata_asset.lower() != usdc.lower():
        raise ctx.fail(f"stata.asset() = {stata_asset}, expected usdc {usdc}")

    if action not in _FRESHLY_RECOGNIZED:
        return  # config equality + asset() (just checked) already prove correctness
    # c2: the adopt run must send no transactions. In adopt mode, skip the
    # live mint/approve/deposit/redeem round-trip (6 txs) -- it spends gas.
    # The read-only checks above (config equality + asset()) already proved
    # correctness without sending any tx.
    mode, _ = resolve_target_mode(ctx.target["aave"])
    if mode == "adopt":
        return

    # One-time live proof: deposit 100 USDC into waUSDC, redeem every share, expect exactly
    # 100 USDC back (index == 1, no interest has accrued). Mint the deployer's 100 USDC first
    # (usdc.py's own one-time proof already makes the deployer a MasterMinter-configured
    # minter with 1,000,000 USDC of allowance -- MODULE_ORDER runs usdc before aave -- but
    # check rather than assume, mirroring funding.py's is_minter guard).
    deployer = ctx.deployer_address
    is_minter = ctx.cast("call", usdc, "isMinter(address)(bool)", deployer) == "true"
    allowance = (
        _uint(ctx.cast("call", usdc, "minterAllowance(address)(uint256)", deployer)) if is_minter else 0
    )
    if not is_minter or allowance < _DEPOSIT_AMOUNT:
        master_minter = usdc_manifest["masterMinter"]
        ctx.send(master_minter, "configureController(address,address)", deployer, deployer)
        ctx.send(master_minter, "configureMinter(uint256)", str(_MINTER_ALLOWANCE))
    ctx.send(usdc, "mint(address,uint256)", deployer, str(_DEPOSIT_AMOUNT))

    ctx.send(usdc, "approve(address,uint256)", wa_usdc, str(_DEPOSIT_AMOUNT))
    ctx.send(wa_usdc, "deposit(uint256,address)", str(_DEPOSIT_AMOUNT), deployer)
    shares = _uint(ctx.cast("call", wa_usdc, "balanceOf(address)(uint256)", deployer))
    balance_before = _uint(ctx.cast("call", usdc, "balanceOf(address)(uint256)", deployer))
    ctx.send(wa_usdc, "redeem(uint256,address,address)", str(shares), deployer, deployer)
    balance_after = _uint(ctx.cast("call", usdc, "balanceOf(address)(uint256)", deployer))

    returned = balance_after - balance_before
    if returned != _DEPOSIT_AMOUNT:
        raise ctx.fail(
            f"deposit {_DEPOSIT_AMOUNT} USDC into waUSDC then redeem all {shares} shares returned "
            f"{returned} USDC, expected exactly {_DEPOSIT_AMOUNT} (index != 1)"
        )
