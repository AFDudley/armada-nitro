"""weth module: deploy WETH9 by sending its exact mainnet runtime bytecode
as contract-creation code. WETH9 has no constructor and no immutables, so
wrapping the runtime in creation code that CODECOPYs and RETURNs it
produces byte-identical deployed code -- no compiler needed.
See docs/ENVIRONMENT.md §6 (weth row) and env/sources.lock.json (weth9).
"""
from __future__ import annotations

import json
from pathlib import Path

from reconciler.context import Context, resolve_target_mode, to_int

# env/sources.lock.json is two directories up from this file
# (env/reconciler/modules/weth.py -> env/).
_SOURCES_LOCK = Path(__file__).resolve().parents[2] / "sources.lock.json"

# Actions that prove correctness by a live deposit/withdraw round-trip, not
# just by reading state. Re-running that proof on an already-reconciled
# module would send transactions on every run, breaking idempotency (and
# the read-only armada-env-verify gate) -- so it runs once, the first time
# this run recognizes the address, and never again.
_FRESHLY_RECOGNIZED = ("deployed", "adopted")


def _weth9_source() -> dict:
    return json.loads(_SOURCES_LOCK.read_text())["weth9"]


def _build_creation_code(runtime_hex: str) -> str:
    """Wrap 0x-prefixed exact runtime bytes in the minimal init code that
    copies them from its own bytecode and returns them:
    PUSH4 <len> DUP1 PUSH1 <offset> PUSH1 0 CODECOPY PUSH1 0 RETURN <runtime>
    """
    runtime = bytes.fromhex(runtime_hex[2:])
    length = len(runtime)
    tail = bytes([0x60, 0, 0x60, 0, 0x39, 0x60, 0, 0xF3])  # PUSH1<off> PUSH1 0 CODECOPY PUSH1 0 RETURN, offset patched below
    header_len = 1 + 4 + 1 + len(tail)  # PUSH4 opcode+data, DUP1, then tail
    tail = bytes([0x60, header_len, 0x60, 0, 0x39, 0x60, 0, 0xF3])
    header = bytes([0x63]) + length.to_bytes(4, "big") + bytes([0x80]) + tail
    assert len(header) == header_len
    return "0x" + (header + runtime).hex()


def observe(ctx: Context) -> str | None:
    return ctx.manifest.get("assets", {}).get("weth")


def apply(ctx: Context, observed: str | None) -> tuple[str, int]:
    mode, params = resolve_target_mode(ctx.target["weth"])
    ctx.manifest.setdefault("assets", {})

    if mode == "adopt":
        address = params["address"]
        action = "present" if observed == address else "adopted"
        ctx.manifest["assets"]["weth"] = address
        return action, 0

    # mode == "deploy": an address already on record is never redeployed,
    # even one that turns out to be bad on-chain -- verify() catches that.
    if observed:
        return "present", 0

    weth9 = _weth9_source()
    creation_code = _build_creation_code(weth9["runtime"])
    receipt = ctx.send("--create", creation_code)
    address = receipt["contractAddress"]
    gas_used = to_int(receipt["gasUsed"])

    ctx.manifest["assets"]["weth"] = address
    ctx.manifest.setdefault("gasUsed", {})
    ctx.manifest["gasUsed"]["weth"] = ctx.manifest["gasUsed"].get("weth", 0) + gas_used
    return "deployed", gas_used


def verify(ctx: Context, action: str) -> None:
    address = ctx.manifest.get("assets", {}).get("weth")
    if not address:
        raise ctx.fail("no weth address recorded; run without --verify-only first")

    weth9 = _weth9_source()
    codehash = ctx.cast("codehash", address)
    if codehash.lower() != weth9["codeHash"].lower():
        raise ctx.fail(f"extcodehash {codehash} != {weth9['codeHash']}")

    if action not in _FRESHLY_RECOGNIZED:
        return  # bytecode identity (just checked) already proves behavior; don't re-spend gas proving it again

    one_eth_wei = "1000000000000000000"
    balance_before = to_int(ctx.cast("balance", ctx.deployer_address))
    deposit = ctx.send(address, "deposit()", "--value", "1ether")
    withdraw = ctx.send(address, "withdraw(uint256)", one_eth_wei)
    balance_after = to_int(ctx.cast("balance", ctx.deployer_address))

    gas_cost = to_int(deposit["gasUsed"]) * to_int(deposit["effectiveGasPrice"]) + to_int(
        withdraw["gasUsed"]
    ) * to_int(withdraw["effectiveGasPrice"])
    actual_change = balance_before - balance_after
    if actual_change != gas_cost:
        raise ctx.fail(
            "deposit/withdraw round-trip: ETH balance changed by "
            f"{actual_change} wei, expected exactly the gas cost {gas_cost} wei"
        )
