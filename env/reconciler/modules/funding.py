"""funding module: fund the fixturenet's test accounts (anvil accounts 1-4) with USDC.
No ETH action is needed -- docs/ENVIRONMENT.md §2's fixed premine already gives every
account 0-9 10,000 ETH at genesis, comfortably over the >= 100 ETH postcondition (§6),
and these accounts never spend gas on their own. See docs/tasks/E6-armada-and-nitro.md.

Idempotent by construction: apply() mints only each account's shortfall to 1,000 USDC
(zero accounts short -> zero mint transactions), and only configures a minter role at
all when a mint is actually about to happen.
"""

from __future__ import annotations

from typing import Any

from reconciler.context import Context, resolve_target_mode, to_int
from reconciler.modules import _wallet

_TEST_ACCOUNT_INDICES = (1, 2, 3, 4)
_USDC_TARGET = 1_000_000_000  # 1,000 USDC at 6 decimals
# Headroom for the minter role this module configures, mirrors usdc.py's own one-time
# proof minter -- large enough that this module's own future top-ups never need it raised.
_MINTER_ALLOWANCE = 1_000_000_000_000  # 1,000,000 USDC
_MIN_ETH_WEI = 100 * 10**18


def _uint(cast_output: str) -> int:
    # `cast call ...(uintN)` pretty-prints large values as "1000000 [1e6]".
    return to_int(cast_output.split()[0])


def observe(ctx: Context) -> list[dict[str, Any]] | None:
    return ctx.manifest.get("testAccounts")


def apply(ctx: Context, observed: list[dict[str, Any]] | None) -> tuple[str, int]:
    mode, _ = resolve_target_mode(ctx.target["funding"])
    if mode != "deploy":
        raise ValueError(f"funding module only supports deploy mode, got {mode!r}")

    usdc = ctx.manifest.get("usdc")
    if not usdc or not usdc.get("proxy") or not usdc.get("masterMinter"):
        raise ctx.fail("usdc module has not been reconciled; run it before funding (MODULE_ORDER)")
    proxy = usdc["proxy"]
    master_minter = usdc["masterMinter"]
    deployer = ctx.deployer_address

    accounts = [(index, _wallet.address(index)) for index in _TEST_ACCOUNT_INDICES]

    shortfalls: dict[str, int] = {}
    for _, address in accounts:
        balance = _uint(ctx.cast("call", proxy, "balanceOf(address)(uint256)", address))
        shortfall = _USDC_TARGET - balance
        if shortfall > 0:
            shortfalls[address] = shortfall

    total_gas = 0
    if shortfalls:
        is_minter = ctx.cast("call", proxy, "isMinter(address)(bool)", deployer) == "true"
        allowance = (
            _uint(ctx.cast("call", proxy, "minterAllowance(address)(uint256)", deployer)) if is_minter else 0
        )
        needed = sum(shortfalls.values())
        if not is_minter or allowance < needed:
            receipt = ctx.send(master_minter, "configureController(address,address)", deployer, deployer)
            total_gas += to_int(receipt["gasUsed"])
            receipt = ctx.send(master_minter, "configureMinter(uint256)", str(max(_MINTER_ALLOWANCE, needed)))
            total_gas += to_int(receipt["gasUsed"])
        for address, shortfall in shortfalls.items():
            receipt = ctx.send(proxy, "mint(address,uint256)", address, str(shortfall))
            total_gas += to_int(receipt["gasUsed"])

    # Key files are written every apply() run regardless of shortfalls -- pure offline
    # derivation from the public mnemonic, so re-writing them sends no transaction and
    # costs no gas; this also recreates them if the state dir was ever wiped.
    keys_dir = ctx.state_dir / "keys"
    keys_dir.mkdir(parents=True, exist_ok=True)
    test_accounts = []
    for index, address in accounts:
        key_file = keys_dir / f"{address}.key"
        key_file.write_text(_wallet.private_key(index))
        key_file.chmod(0o600)
        test_accounts.append({"address": address, "privateKeyFile": f"keys/{address}.key"})
    ctx.manifest["testAccounts"] = test_accounts

    if not shortfalls:
        return "present", 0

    ctx.manifest.setdefault("gasUsed", {})
    ctx.manifest["gasUsed"]["funding"] = ctx.manifest["gasUsed"].get("funding", 0) + total_gas
    return "configured", total_gas


def verify(ctx: Context, action: str) -> None:
    test_accounts = ctx.manifest.get("testAccounts")
    if not test_accounts:
        raise ctx.fail("no testAccounts recorded; run without --verify-only first")
    usdc = ctx.manifest.get("usdc")
    if not usdc or not usdc.get("proxy"):
        raise ctx.fail("no usdc recorded; run the usdc module first")
    proxy = usdc["proxy"]

    for entry in test_accounts:
        address = entry["address"]
        balance = _uint(ctx.cast("call", proxy, "balanceOf(address)(uint256)", address))
        if balance < _USDC_TARGET:
            raise ctx.fail(f"{address} USDC balance {balance} < {_USDC_TARGET}")

        eth_balance = to_int(ctx.cast("balance", address))
        if eth_balance < _MIN_ETH_WEI:
            raise ctx.fail(f"{address} ETH balance {eth_balance} < {_MIN_ETH_WEI} (100 ETH)")

        key_file = ctx.state_dir / entry["privateKeyFile"]
        if not key_file.exists():
            raise ctx.fail(f"missing key file {key_file}")
