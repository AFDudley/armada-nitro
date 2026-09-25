"""usdc module: deploy Circle's FiatToken USDC (FiatTokenV2_2 implementation,
FiatTokenProxy, MasterMinter) from stablecoin-evm's
scripts/deploy/deploy-fiat-token.s.sol, driven by the environment variables
that script reads. See docs/ENVIRONMENT.md §6 (usdc row) and E3b's USDC
bytecode oracle.

Deviation from the E3b brief (recorded here with evidence, per the worker
protocol's "stop and report a wrong fact" rule -- this one narrow point,
not the module as a whole, since everything else it depends on holds):
deploy-fiat-token.s.sol does NOT read a LOST_AND_FOUND_ADDRESS environment
variable. It hard-codes `owner` as the `lostAndFound` argument to
initializeV2_1 (see the script's `_deploy`: `proxyAsV2_2.initializeV2_1(owner)`).
FiatTokenV2_1.initializeV2_1 only ever *uses* that address to sweep a
locked balance at the token contract itself; a fresh deployment has no such
balance, so the argument has no on-chain effect either way here. The
manifest schema (docs/ENVIRONMENT.md §5) does not record a `lostAndFound`
key. So the target's "lostAndFound = account 9" role cannot be wired
through this pinned script without editing it (out of scope), and has no
observable effect if it could be -- it is intentionally not a parameter
of this module.

PROXY_ADMIN_ADDRESS is a required input the script reads that the brief
does not name. It must differ from owner/masterMinterOwner/pauser/
blacklister: FiatTokenProxy (AdminUpgradeabilityProxy) reverts non-admin-
function calls made *by* its own admin ("Cannot call fallback function
from the proxy admin", contracts/upgradeability/AdminUpgradeabilityProxy.sol
`_willFallback`), so if the proxy admin were also the owner/pauser/etc.,
transfers, mints and blacklist calls from that account would revert. The
fixturenet target uses anvil account 9 for this, distinct from every other
USDC role.
"""
from __future__ import annotations

import json
from pathlib import Path

from reconciler.context import CastError, Context, resolve_target_mode, to_int
from reconciler.modules import _forge

_STABLECOIN_EVM = Path("/src/stablecoin-evm")
_SCRIPT_TARGET = "scripts/deploy/deploy-fiat-token.s.sol:DeployFiatToken"
_ARTIFACT = _STABLECOIN_EVM / "artifacts/foundry/FiatTokenV2_2.sol/FiatTokenV2_2.json"

# Oracle reference points (docs/tasks/E3b-usdc-cctp.md "USDC bytecode oracle").
_MAINNET_RPC = "https://ethereum-rpc.publicnode.com"
_SEPOLIA_RPC = "https://ethereum-sepolia-rpc.publicnode.com"
_MAINNET_USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
_SEPOLIA_USDC = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
# keccak256("org.zeppelinos.proxy.implementation") - the EIP1967-predecessor
# slot FiatTokenProxy's AdminUpgradeabilityProxy stores its implementation in.
_IMPLEMENTATION_SLOT = "0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3"

# anvil account 1 (test test ... junk, index 1): transfer recipient only in
# the one-time proof below. No key needed -- it never signs anything.
_TRANSFER_RECIPIENT = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

# Actions that prove correctness by live transactions (configuring a minter,
# minting, transferring), not just by reading state. Re-running that proof
# on an already-reconciled module would break idempotency, so it runs once,
# the first time this run recognizes the address, and never again. Mirrors
# weth.py's _FRESHLY_RECOGNIZED.
_FRESHLY_RECOGNIZED = ("deployed", "adopted")


def _artifact() -> dict:
    return json.loads(_ARTIFACT.read_text())


def _link_reference_slices() -> list[tuple[int, int]]:
    """(start, length) byte offsets of every library link slot in
    FiatTokenV2_2's deployed bytecode, read from the build artifact (never
    hard-coded -- offsets can move if the source or optimizer changes)."""
    refs = _artifact()["deployedBytecode"]["linkReferences"]
    return [
        (entry["start"], entry["length"])
        for file_refs in refs.values()
        for entry_list in file_refs.values()
        for entry in entry_list
    ]


def _strip_metadata_trailer(code: bytes) -> bytes:
    """The last two bytes of Solidity-produced runtime code are the
    big-endian length of the trailing CBOR metadata blob; drop the blob and
    its own two-byte length field."""
    if len(code) < 2:
        return code
    cbor_len = int.from_bytes(code[-2:], "big")
    return code[: len(code) - (cbor_len + 2)]


def _zero_link_slots(code: bytes) -> bytes:
    buf = bytearray(code)
    for start, length in _link_reference_slices():
        buf[start : start + length] = b"\x00" * length
    return bytes(buf)


def _normalized_runtime(ctx: Context, address: str, rpc_url: str) -> bytes:
    code_hex = ctx.cast("code", address, rpc_url=rpc_url)
    code = bytes.fromhex(code_hex[2:])
    return _zero_link_slots(_strip_metadata_trailer(code))


def _diff_count(a: bytes, b: bytes) -> int:
    n = max(len(a), len(b))
    a = a.ljust(n, b"\x00")
    b = b.ljust(n, b"\x00")
    return sum(1 for x, y in zip(a, b) if x != y)


def _uint(cast_output: str) -> int:
    # `cast call ...(uintN)` pretty-prints large values as "1000000 [1e6]";
    # to_int() only handles bare hex/decimal, so drop the annotation first.
    return to_int(cast_output.split()[0])


def _implementation_of(ctx: Context, proxy: str, rpc_url: str) -> str:
    slot = ctx.cast("storage", proxy, _IMPLEMENTATION_SLOT, rpc_url=rpc_url)
    return "0x" + slot[-40:]


def observe(ctx: Context) -> dict | None:
    return ctx.manifest.get("usdc")


def apply(ctx: Context, observed: dict | None) -> tuple[str, int]:
    mode, params = resolve_target_mode(ctx.target["usdc"])

    if mode == "adopt":
        proxy = params["proxy"]
        action = "present" if observed and observed.get("proxy") == proxy else "adopted"
        ctx.manifest["usdc"] = {
            "proxy": proxy,
            "implementation": params["implementation"],
            "masterMinter": params["masterMinter"],
        }
        return action, 0

    # mode == "deploy": an address already on record is never redeployed.
    if observed and observed.get("proxy"):
        return "present", 0

    chain_id = ctx.target["network"]["chainId"]
    env = {
        "TOKEN_NAME": params["name"],
        "TOKEN_SYMBOL": params["symbol"],
        "TOKEN_CURRENCY": params["currency"],
        "TOKEN_DECIMALS": str(params["decimals"]),
        "PROXY_ADMIN_ADDRESS": params["proxyAdmin"],
        "MASTER_MINTER_OWNER_ADDRESS": params["masterMinterOwner"],
        "OWNER_ADDRESS": params["owner"],
        "PAUSER_ADDRESS": params["pauser"],
        "BLACKLISTER_ADDRESS": params["blacklister"],
        "DEPLOYER_PRIVATE_KEY": ctx.deployer_key,
    }
    receipts = _forge.run_broadcast(
        project_dir=_STABLECOIN_EVM,
        script_target=_SCRIPT_TARGET,
        rpc_url=ctx.rpc_url,
        chain_id=chain_id,
        env=env,
    )
    gas_used = _forge.sum_gas_used(receipts)

    ctx.manifest["usdc"] = {
        "proxy": _forge.created_contract_address(receipts, "FiatTokenProxy"),
        "implementation": _forge.created_contract_address(receipts, "FiatTokenV2_2"),
        "masterMinter": _forge.created_contract_address(receipts, "MasterMinter"),
    }
    ctx.manifest.setdefault("gasUsed", {})
    ctx.manifest["gasUsed"]["usdc"] = ctx.manifest["gasUsed"].get("usdc", 0) + gas_used
    return "deployed", gas_used


def verify(ctx: Context, action: str) -> None:
    usdc = ctx.manifest.get("usdc")
    if not usdc:
        raise ctx.fail("no usdc recorded; run without --verify-only first")
    proxy = usdc["proxy"]

    name = json.loads(ctx.cast("call", proxy, "name()(string)"))
    if name != "USDC":
        raise ctx.fail(f"name() = {name!r}, expected 'USDC'")
    symbol = json.loads(ctx.cast("call", proxy, "symbol()(string)"))
    if symbol != "USDC":
        raise ctx.fail(f"symbol() = {symbol!r}, expected 'USDC'")
    decimals = int(ctx.cast("call", proxy, "decimals()(uint8)"))
    if decimals != 6:
        raise ctx.fail(f"decimals() = {decimals}, expected 6")

    master_minter = ctx.cast("call", proxy, "masterMinter()(address)")
    if master_minter.lower() != usdc["masterMinter"].lower():
        raise ctx.fail(f"masterMinter() = {master_minter}, expected {usdc['masterMinter']}")

    # version() must equal Sepolia USDC's, read at run time (docs/ENVIRONMENT.md §6).
    version = json.loads(ctx.cast("call", proxy, "version()(string)"))
    sepolia_version = json.loads(ctx.cast("call", _SEPOLIA_USDC, "version()(string)", rpc_url=_SEPOLIA_RPC))
    if version != sepolia_version:
        raise ctx.fail(f"version() = {version!r}, Sepolia USDC's version() = {sepolia_version!r}")

    # Negative case: mint from an unconfigured minter reverts. A `cast call`
    # (eth_call) sends no transaction, so this runs on every verify(),
    # including read-only --verify-only / armada-env-verify runs.
    try:
        ctx.cast(
            "call", "--from", _TRANSFER_RECIPIENT, proxy,
            "mint(address,uint256)", _TRANSFER_RECIPIENT, "1000000",
        )
    except CastError as e:
        if "caller is not a minter" not in str(e):
            raise ctx.fail(f"mint() from an unconfigured minter reverted for the wrong reason: {e}")
    else:
        raise ctx.fail("mint() from an unconfigured minter did not revert")

    # USDC bytecode oracle: the implementation's runtime must equal mainnet
    # USDC's, byte for byte, after normalization.
    fixturenet_impl = _implementation_of(ctx, proxy, ctx.rpc_url)
    if fixturenet_impl.lower() != usdc["implementation"].lower():
        raise ctx.fail(
            f"proxy implementation slot = {fixturenet_impl}, manifest usdc.implementation = {usdc['implementation']}"
        )
    mainnet_impl = _implementation_of(ctx, _MAINNET_USDC, _MAINNET_RPC)
    fixturenet_runtime = _normalized_runtime(ctx, fixturenet_impl, ctx.rpc_url)
    mainnet_runtime = _normalized_runtime(ctx, mainnet_impl, _MAINNET_RPC)
    diff = _diff_count(fixturenet_runtime, mainnet_runtime)
    print(
        "usdc bytecode oracle: fixturenet normalized length="
        f"{len(fixturenet_runtime)}, mainnet normalized length={len(mainnet_runtime)}, differing bytes={diff}"
    )
    if fixturenet_runtime != mainnet_runtime:
        raise ctx.fail(
            f"implementation runtime != mainnet USDC's implementation after normalization ({diff} differing bytes)"
        )

    if action not in _FRESHLY_RECOGNIZED:
        return  # bytecode identity + read-only checks (just run) already proved correctness

    # One-time live proof: masterMinter can configure a minter, and that
    # minter can mint; transfer works. Uses the deployer both as the
    # MasterMinter's controller and as the minter/worker it configures.
    deployer = ctx.deployer_address
    ctx.send(master_minter, "configureController(address,address)", deployer, deployer)
    ctx.send(master_minter, "configureMinter(uint256)", "1000000000000")
    ctx.send(proxy, "mint(address,uint256)", deployer, "1000000")
    balance_before = _uint(ctx.cast("call", proxy, "balanceOf(address)(uint256)", _TRANSFER_RECIPIENT))
    ctx.send(proxy, "transfer(address,uint256)", _TRANSFER_RECIPIENT, "1000000")
    balance_after = _uint(ctx.cast("call", proxy, "balanceOf(address)(uint256)", _TRANSFER_RECIPIENT))
    if balance_after - balance_before != 1000000:
        raise ctx.fail(
            f"transfer: {_TRANSFER_RECIPIENT} balance changed by {balance_after - balance_before}, expected 1000000"
        )
