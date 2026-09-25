"""cctp module: deploy Circle's CCTP v2 (MessageTransmitterV2,
TokenMessengerV2, TokenMinterV2, and the CREATE2 factory their proxies are
deployed through) from evm-cctp-contracts' scripts/v2/*.s.sol, driven by
the environment variables those scripts read. See docs/ENVIRONMENT.md §6
(cctp row) and docs/tasks/E3b-usdc-cctp.md.

The pinned scripts need many more role addresses than the brief names
(owner/pauser/rescuer/denylister/fee-recipient/proxy-admin for the message
transmitter and token messenger, a token controller, a token-minter owner
key, a CREATE2 factory owner). None of §6's postconditions constrain these
roles, so every one of them is the deployer (ctx.deployer_address) except
the two the brief does name: DOMAIN and the one real attester. This is
safe: `AdminUpgradableProxy` (src/proxy/AdminUpgradableProxy.sol) is a fork
of OZ's UpgradeableProxy with `_beforeFallback`'s admin-can't-call-through
guard deliberately removed (its own doc comment says so), unlike
stablecoin-evm's proxy, so the deployer can double as every proxy's admin
without breaking calls to those proxies' non-admin functions.

MessageTransmitterV2.initialize requires exactly two attesters and a
signature threshold that does not exceed the attester count (>= 1); the
deploy script's threshold is hard-coded to 2 for a two-attester quorum.
There is no way to initialize with a single attester through this script.
To reach the target's "one attester = anvil account 8", this module
initializes with a second, disposable attester address, then -- through
the contract's own post-deploy admin API (Attestable.setSignatureThreshold,
Attestable.disableAttester; both public, both onlyAttesterManager) -- lowers
the threshold to 1 and disables the disposable attester. No script is
edited to do this.

BURN_LIMIT_PER_MESSAGE and the USDC minter allowance this module gives
TokenMinterV2 (through the usdc module's MasterMinter, "mint allowance
configured by the usdc module's masterMinter" per the brief) are not
constrained by any §6 postcondition; mainnet's TokenMinterV2 burn limit for
USDC (10,000,000 USDC = 1e13 base units, read from mainnet TokenMinterV2
`burnLimitsPerMessage(usdc)` at 0xfd78EE919681417d192449715b2594ab58f5D002)
sizes both here.
"""
from __future__ import annotations

from pathlib import Path

from reconciler.context import CastError, Context, resolve_target_mode, to_int
from reconciler.modules import _forge

_CCTP_CONTRACTS = Path("/src/evm-cctp-contracts")

# Sepolia v2 MessageTransmitter the cctp postcondition (§6: "version() equals
# the Sepolia v2 transmitter's") reads at run time -- the same address
# demo3 used (armada-poc deployments/privacy-pool-hub-sepolia.json,
# key cctp.messageTransmitter), per docs/tasks/E3b-usdc-cctp.md.
_SEPOLIA_RPC = "https://ethereum-sepolia-rpc.publicnode.com"
_SEPOLIA_MESSAGE_TRANSMITTER = "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275"

# CCTP v2's message body version is 1 on every live deployment (read from
# Sepolia's real TokenMessengerV2, 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA,
# `messageBodyVersion()`); it is not itself a §6 postcondition, so it is
# recorded here rather than re-read on every run.
_MESSAGE_BODY_VERSION = 1

# Disposable second attester MessageTransmitterV2.initialize needs (see
# module docstring); disabled by this module immediately after deploy.
_PLACEHOLDER_ATTESTER = "0x000000000000000000000000000000000000dEaD"


def observe(ctx: Context) -> dict | None:
    return ctx.manifest.get("cctp")


def apply(ctx: Context, observed: dict | None) -> tuple[str, int]:
    mode, params = resolve_target_mode(ctx.target["cctp"])

    if mode == "adopt":
        token_messenger = params["tokenMessenger"]
        action = "present" if observed and observed.get("tokenMessenger") == token_messenger else "adopted"
        ctx.manifest["cctp"] = {
            "tokenMessenger": token_messenger,
            "messageTransmitter": params["messageTransmitter"],
            "tokenMinter": params["tokenMinter"],
            "domain": params["domain"],
        }
        return action, 0

    # mode == "deploy": addresses already on record are never redeployed.
    if observed and observed.get("tokenMessenger"):
        return "present", 0

    usdc = ctx.manifest.get("usdc")
    if not usdc or not usdc.get("proxy") or not usdc.get("masterMinter"):
        raise ctx.fail("usdc module has not been reconciled; run it before cctp (MODULE_ORDER)")

    chain_id = ctx.target["network"]["chainId"]
    domain = params["domain"]
    attester = params["attester"]
    min_fee = params.get("minFee", 0)
    burn_limit = params["burnLimitPerMessage"]
    deployer = ctx.deployer_address
    usdc_proxy = usdc["proxy"]
    total_gas = 0

    version = int(ctx.cast("call", _SEPOLIA_MESSAGE_TRANSMITTER, "version()(uint32)", rpc_url=_SEPOLIA_RPC))

    factory_receipts = _forge.run_broadcast(
        project_dir=_CCTP_CONTRACTS,
        script_target="scripts/DeployCreate2Factory.s.sol:DeployCreate2FactoryScript",
        rpc_url=ctx.rpc_url,
        chain_id=chain_id,
        env={"CREATE2_FACTORY_OWNER": deployer},
        extra_args=("--private-keys", ctx.deployer_key),
    )
    total_gas += _forge.sum_gas_used(factory_receipts)
    factory = _forge.created_contract_address(factory_receipts, "Create2Factory")

    impl_receipts = _forge.run_broadcast(
        project_dir=_CCTP_CONTRACTS,
        script_target="scripts/v2/DeployImplementationsV2.s.sol:DeployImplementationsV2Script",
        rpc_url=ctx.rpc_url,
        chain_id=chain_id,
        env={
            "CREATE2_FACTORY_CONTRACT_ADDRESS": factory,
            "TOKEN_MINTER_V2_OWNER_KEY": ctx.deployer_key,
            "TOKEN_CONTROLLER_ADDRESS": deployer,
            "DOMAIN": str(domain),
            "MESSAGE_BODY_VERSION": str(_MESSAGE_BODY_VERSION),
            "VERSION": str(version),
        },
        extra_args=("--private-keys", ctx.deployer_key),
    )
    total_gas += _forge.sum_gas_used(impl_receipts)
    token_minter = _forge.additional_contract_addresses(impl_receipts, "TokenMinterV2")[0]

    remote_usdc_bytes32 = "0x" + "00" * 12 + usdc_proxy[2:].lower()
    proxies_receipts = _forge.run_broadcast(
        project_dir=_CCTP_CONTRACTS,
        script_target="scripts/v2/DeployProxiesV2.s.sol:DeployProxiesV2Script",
        rpc_url=ctx.rpc_url,
        chain_id=chain_id,
        env={
            "USDC_CONTRACT_ADDRESS": usdc_proxy,
            "REMOTE_USDC_CONTRACT_ADDRESSES": remote_usdc_bytes32,
            "CREATE2_FACTORY_CONTRACT_ADDRESS": factory,
            "MESSAGE_TRANSMITTER_V2_OWNER_ADDRESS": deployer,
            "MESSAGE_TRANSMITTER_V2_PAUSER_ADDRESS": deployer,
            "MESSAGE_TRANSMITTER_V2_RESCUER_ADDRESS": deployer,
            "MESSAGE_TRANSMITTER_V2_ATTESTER_MANAGER_ADDRESS": deployer,
            "MESSAGE_TRANSMITTER_V2_ATTESTER_1_ADDRESS": attester,
            "MESSAGE_TRANSMITTER_V2_ATTESTER_2_ADDRESS": _PLACEHOLDER_ATTESTER,
            "MESSAGE_TRANSMITTER_V2_PROXY_ADMIN_ADDRESS": deployer,
            "TOKEN_MINTER_V2_PAUSER_ADDRESS": deployer,
            "TOKEN_MINTER_V2_RESCUER_ADDRESS": deployer,
            "TOKEN_MESSENGER_V2_OWNER_ADDRESS": deployer,
            "TOKEN_MESSENGER_V2_RESCUER_ADDRESS": deployer,
            "TOKEN_MESSENGER_V2_FEE_RECIPIENT_ADDRESS": deployer,
            "TOKEN_MESSENGER_V2_DENYLISTER_ADDRESS": deployer,
            "TOKEN_MESSENGER_V2_PROXY_ADMIN_ADDRESS": deployer,
            "TOKEN_MESSENGER_V2_MIN_FEE_CONTROLLER_ADDRESS": deployer,
            "TOKEN_MESSENGER_V2_MIN_FEE": str(min_fee),
            "DOMAIN": str(domain),
            "VERSION": str(version),
            "MESSAGE_BODY_VERSION": str(_MESSAGE_BODY_VERSION),
            "REMOTE_DOMAINS": str(domain),
            "BURN_LIMIT_PER_MESSAGE": str(burn_limit),
            "CREATE2_FACTORY_OWNER": deployer,
            "TOKEN_MINTER_V2_OWNER_KEY": ctx.deployer_key,
            "TOKEN_CONTROLLER_KEY": ctx.deployer_key,
        },
        extra_args=("--private-keys", ctx.deployer_key),
    )
    total_gas += _forge.sum_gas_used(proxies_receipts)
    proxies = _forge.additional_contract_addresses(proxies_receipts, "AdminUpgradableProxy")
    message_transmitter, token_messenger = proxies[0], proxies[1]

    # Reach "one attester" (module docstring): lower the threshold before
    # disabling the placeholder -- disableAttester refuses to drop the
    # enabled count to or below the current threshold.
    receipt = ctx.send(message_transmitter, "setSignatureThreshold(uint256)", "1")
    total_gas += to_int(receipt["gasUsed"])
    receipt = ctx.send(message_transmitter, "disableAttester(address)", _PLACEHOLDER_ATTESTER)
    total_gas += to_int(receipt["gasUsed"])

    # "mint allowance configured by the usdc module's masterMinter": make
    # TokenMinterV2 a minter on the FiatToken proxy through its MasterMinter.
    master_minter = usdc["masterMinter"]
    receipt = ctx.send(master_minter, "configureController(address,address)", deployer, token_minter)
    total_gas += to_int(receipt["gasUsed"])
    receipt = ctx.send(master_minter, "configureMinter(uint256)", str(burn_limit))
    total_gas += to_int(receipt["gasUsed"])

    ctx.manifest["cctp"] = {
        "tokenMessenger": token_messenger,
        "messageTransmitter": message_transmitter,
        "tokenMinter": token_minter,
        "domain": domain,
    }
    ctx.manifest.setdefault("gasUsed", {})
    ctx.manifest["gasUsed"]["cctp"] = ctx.manifest["gasUsed"].get("cctp", 0) + total_gas
    return "deployed", total_gas


def verify(ctx: Context, action: str) -> None:
    cctp = ctx.manifest.get("cctp")
    if not cctp:
        raise ctx.fail("no cctp recorded; run without --verify-only first")
    message_transmitter = cctp["messageTransmitter"]
    token_messenger = cctp["tokenMessenger"]
    token_minter = cctp["tokenMinter"]
    domain = cctp["domain"]

    local_domain = int(ctx.cast("call", message_transmitter, "localDomain()(uint32)"))
    if local_domain != domain:
        raise ctx.fail(f"messageTransmitter.localDomain() = {local_domain}, expected {domain}")

    local_transmitter = ctx.cast("call", token_messenger, "localMessageTransmitter()(address)")
    if local_transmitter.lower() != message_transmitter.lower():
        raise ctx.fail(
            f"tokenMessenger.localMessageTransmitter() = {local_transmitter}, expected {message_transmitter}"
        )

    usdc_proxy = ctx.manifest["usdc"]["proxy"]
    remote_usdc_bytes32 = "0x" + "00" * 12 + usdc_proxy[2:].lower()
    local_token = ctx.cast("call", token_minter, "getLocalToken(uint32,bytes32)(address)", str(domain), remote_usdc_bytes32)
    if local_token.lower() != usdc_proxy.lower():
        raise ctx.fail(f"tokenMinter.getLocalToken({domain}, usdc) = {local_token}, expected {usdc_proxy} (USDC not listed as a local token)")

    version = int(ctx.cast("call", message_transmitter, "version()(uint32)"))
    sepolia_version = int(ctx.cast("call", _SEPOLIA_MESSAGE_TRANSMITTER, "version()(uint32)", rpc_url=_SEPOLIA_RPC))
    if version != sepolia_version:
        raise ctx.fail(f"messageTransmitter.version() = {version}, Sepolia v2 transmitter's version() = {sepolia_version}")
