"""armada_sol module: deploy PoolSol, the pool contract that armada-laconic-mono's armada-sol emits
from its Lean declaration (`armada-sol/ArmadaSol/PoolContract.lean`), next to Armada's own pool.

The source is vendored at env/armada-sol/PoolSol.sol, because the monorepo is private and the
image clones sources anonymously. env/armada-sol/provenance.json records the monorepo commit, the
source's SHA-256, the solc profile, and the SHA-256 of the runtime bytecode that the Lean bytecode
statements are about (`ArmadaSol/Bytecode/Pool/Code.lean`), with the link and immutable offsets.
See env/armada-sol/README.md.

apply() compiles the source with solc 0.8.31 under the recorded profile, links the PoseidonT3 and
PoseidonT4 contracts that the armada module records (Armada's own deploy creates them), and passes
the verifying keys of Armada's circuit build (/src/armada-circuits/build/<n>x<m>/vkey.json) and the
target's initial fee ratio to the constructor, for the shapes that Armada's deploy registers. The
constructor sets the fee ratio and the empty-tree root (armada-laconic labbook
2026-11-24-pool-for-nitro.md, item P1), and is the only writer of the keys. The circuit release has
no owned circuit, so the owned key list is empty.

apply() redeploys when the recorded `monorepoCommit` differs from provenance.json's: a deployed pool
of a different version is not a match, so apply() deploys the current version and replaces the
manifest entry.

verify() checks two oracles from outside the code under test:
- the deployed runtime, with the link and immutable bytes set to zero, has the SHA-256 that the
  provenance records from the Lean statement; the link bytes are the recorded Poseidon addresses;
  the immutable bytes are the fee admin and the maximum batch;
- for each shape, the key in storage (read by solc's storage layout) is equal to the key that the
  demo3 pool on Sepolia returns from `getVerificationKey`.
"""

from __future__ import annotations

from typing import Any

import hashlib
import json
import subprocess
from pathlib import Path

from reconciler.context import CastError, Context, resolve_target_mode, to_int
from reconciler.modules import _wallet
from reconciler.modules._circuits import CIRCUITS_BUILD_DIR
from reconciler.modules.armada import _SEPOLIA_POOL, _TESTING_ARTIFACT_CONFIGS

_SOURCE_DIR = Path(__file__).resolve().parents[2] / "armada-sol"
_SOURCE = _SOURCE_DIR / "PoolSol.sol"
_PROVENANCE = _SOURCE_DIR / "provenance.json"

# The svm-rs path where the image's solc stage puts solc 0.8.31
# (stack/container-build/cerc-armada-nitro-env/Dockerfile, stage `solc-pool`).
_SOLC = Path("/root/.svm/0.8.31/solc-0.8.31")

# The treasury is Armada's (armada.py `_TREASURY_ACCOUNT_INDEX`); the fee admin is an account that
# no other module uses, so a scenario can call `setFeeRatio` with a known key.
_TREASURY_ACCOUNT_INDEX = 7
_FEE_ADMIN_ACCOUNT_INDEX = 8

# The constructor's parameters: `ShapedKey` is (nullifiers, commitments, VerifyingKey), and
# `VerifyingKey` is (artifactsIPFSHash, alpha1, beta2, gamma2, delta2, ic) (out/PoolSol.sol).
_VK_TYPE = "(string,(uint256,uint256),(uint256[2],uint256[2]),(uint256[2],uint256[2]),(uint256[2],uint256[2]),(uint256,uint256)[])"
_CONSTRUCTOR_SIG = f"constructor(address,address,uint256,uint128,uint128,(uint256,uint256,{_VK_TYPE})[],(uint256,uint256,{_VK_TYPE})[])"

# solc's storage layout of PoolSol: `verificationKeys` is the mapping at slot 24, and a
# `VerifyingKey` takes the string at +0, ten words at +1..+14 and the `ic` array at +15
# (armada-sol/ArmadaSol/Bytecode/Pool/Decode.lean, the same table).
_VERIFICATION_KEYS_SLOT = 24
_WORD = 1 << 256


def _provenance() -> dict[str, Any]:
    prov: dict[str, Any] = json.loads(_PROVENANCE.read_text())
    actual = hashlib.sha256(_SOURCE.read_bytes()).hexdigest()
    if actual != prov["sourceSha256"]:
        raise CastError(f"{_SOURCE} sha256 = {actual}, provenance.json records {prov['sourceSha256']}")
    return prov


def _compile(prov: dict[str, Any]) -> dict[str, Any]:
    """solc's creation bytecode and its link references, under the recorded profile."""
    profile = prov["solc"]
    request = {
        "language": "Solidity",
        "sources": {"PoolSol.sol": {"content": _SOURCE.read_text()}},
        "settings": {
            "viaIR": profile["viaIR"],
            "optimizer": {"enabled": True, "runs": profile["optimizerRuns"]},
            "evmVersion": profile["evmVersion"],
            "outputSelection": {
                "PoolSol.sol": {"PoolSol": ["evm.bytecode.object", "evm.bytecode.linkReferences"]}
            },
        },
    }
    result = subprocess.run(
        [str(_SOLC), "--standard-json"], input=json.dumps(request), capture_output=True, text=True
    )
    if result.returncode != 0:
        raise CastError(f"solc failed (exit {result.returncode}): {result.stderr.strip()}")
    output = json.loads(result.stdout)
    errors = [e["formattedMessage"] for e in output.get("errors", []) if e["severity"] == "error"]
    if errors:
        raise CastError("solc errors: " + "; ".join(errors))
    return dict(output["contracts"]["PoolSol.sol"]["PoolSol"]["evm"]["bytecode"])


def _link(bytecode: dict[str, Any], addresses: dict[str, str]) -> str:
    code: str = bytecode["object"]
    for libs in bytecode["linkReferences"].values():
        for lib, refs in libs.items():
            address = addresses[lib].lower().removeprefix("0x")
            for ref in refs:
                start = 2 * ref["start"]
                code = code[:start] + address + code[start + 40 :]
    return code


def _vk_value(n: int, m: int) -> str:
    """The key of shape (n, m) as a `cast abi-encode` tuple, formatted as Armada's
    `formatVKeyForSolidity` (lib/artifacts.ts) formats it: G2 coordinates swapped, and the
    `QmPOC_<n>x<m>` artifacts hash."""
    vk = json.loads((CIRCUITS_BUILD_DIR / f"{n}x{m}" / "vkey.json").read_text())

    def g1(p: list[str]) -> str:
        return f"({p[0]},{p[1]})"

    def g2(p: list[list[str]]) -> str:
        return f"([{p[0][1]},{p[0][0]}],[{p[1][1]},{p[1][0]}])"

    ic = ",".join(g1(p) for p in vk["IC"])
    return (
        f"(QmPOC_{n}x{m},{g1(vk['vk_alpha_1'])},{g2(vk['vk_beta_2'])},{g2(vk['vk_gamma_2'])},"
        f"{g2(vk['vk_delta_2'])},[{ic}])"
    )


def observe(ctx: Context) -> dict[str, Any] | None:
    return ctx.manifest.get("armadaSol")


def apply(ctx: Context, observed: dict[str, Any] | None) -> tuple[str, int]:
    mode, params = resolve_target_mode(ctx.target["armada_sol"])
    if mode != "deploy":
        raise ctx.fail("armada_sol supports only deploy")
    prov = _provenance()
    if observed and observed.get("pool") and observed.get("monorepoCommit") == prov["monorepoCommit"]:
        return "present", 0

    armada = ctx.manifest.get("armada")
    if not armada or not armada.get("poseidonT3") or not armada.get("poseidonT4"):
        raise ctx.fail(
            "armada has not recorded its Poseidon contracts; run it before armada_sol (MODULE_ORDER)"
        )

    code = _link(_compile(prov), {"PoseidonT3": armada["poseidonT3"], "PoseidonT4": armada["poseidonT4"]})
    fee_admin = _wallet.address(_FEE_ADMIN_ACCOUNT_INDEX)
    treasury = _wallet.address(_TREASURY_ACCOUNT_INDEX)
    max_batch = int(params["maxBatch"])
    fee_num = int(params["feeNum"])
    fee_den = int(params["feeDen"])
    keys = "[" + ",".join(f"({n},{m},{_vk_value(n, m)})" for n, m in _TESTING_ARTIFACT_CONFIGS) + "]"
    args = ctx._run(
        [
            "cast",
            "abi-encode",
            _CONSTRUCTOR_SIG,
            fee_admin,
            treasury,
            str(max_batch),
            str(fee_num),
            str(fee_den),
            keys,
            "[]",
        ]
    )

    receipt = ctx.send("--create", "0x" + code + args.removeprefix("0x"))
    if to_int(receipt["status"]) != 1:
        raise ctx.fail(f"PoolSol deploy reverted: tx {receipt['transactionHash']}")
    gas_used = to_int(receipt["gasUsed"])

    ctx.manifest["armadaSol"] = {
        "pool": receipt["contractAddress"],
        "deployBlock": to_int(receipt["blockNumber"]),
        "feeAdmin": fee_admin,
        "treasury": treasury,
        "maxBatch": max_batch,
        "poseidonT3": armada["poseidonT3"],
        "poseidonT4": armada["poseidonT4"],
        "monorepoCommit": prov["monorepoCommit"],
    }
    ctx.manifest.setdefault("gasUsed", {})
    ctx.manifest["gasUsed"]["armada_sol"] = ctx.manifest["gasUsed"].get("armada_sol", 0) + gas_used
    return "deployed", gas_used


def _word(n: int) -> str:
    return "0x" + format(n % _WORD, "064x")


def _storage(ctx: Context, pool: str, slot: int) -> int:
    return int(ctx.cast("storage", pool, _word(slot)), 16)


def _stored_vk(ctx: Context, pool: str, n: int, m: int) -> str:
    """The key of shape (n, m) read from storage, ABI-encoded as `getVerificationKey` returns it."""
    # `cast index` and `cast keccak` are offline and take no --rpc-url, so they run through `_run`.
    outer = ctx._run(["cast", "index", "uint256", str(n), str(_VERIFICATION_KEYS_SLOT)])
    base = int(ctx._run(["cast", "index", "uint256", str(m), outer]), 16)
    head = _storage(ctx, pool, base)
    if head & 1:
        raise ctx.fail(
            f"artifactsIPFSHash of shape ({n},{m}) is a long string; the check reads only short ones"
        )
    text = head.to_bytes(32, "big")[: (head & 0xFF) // 2].decode()
    w = [_storage(ctx, pool, base + i) for i in range(1, 15)]
    ic_len = _storage(ctx, pool, base + 15)
    ic_base = int(ctx._run(["cast", "keccak", _word(base + 15)]), 16)
    ic = [
        (_storage(ctx, pool, ic_base + 2 * i), _storage(ctx, pool, ic_base + 2 * i + 1))
        for i in range(ic_len)
    ]
    value = (
        f"({text},({w[0]},{w[1]}),([{w[2]},{w[3]}],[{w[4]},{w[5]}]),([{w[6]},{w[7]}],[{w[8]},{w[9]}]),"
        f"([{w[10]},{w[11]}],[{w[12]},{w[13]}]),[" + ",".join(f"({x},{y})" for x, y in ic) + "])"
    )
    return ctx._run(["cast", "abi-encode", f"f({_VK_TYPE})", value])


def _check_code(ctx: Context, sol: dict[str, Any], prov: dict[str, Any]) -> None:
    code = bytearray(bytes.fromhex(ctx.cast("code", sol["pool"]).removeprefix("0x")))
    if len(code) != prov["runtimeLength"]:
        raise ctx.fail(f"runtime is {len(code)} bytes, provenance.json records {prov['runtimeLength']}")
    expected = {
        **{start: (20, sol["poseidonT3"]) for start in prov["links"]["PoseidonT3"]},
        **{start: (20, sol["poseidonT4"]) for start in prov["links"]["PoseidonT4"]},
        **{start: (32, sol["feeAdmin"]) for start in prov["immutables"]["feeAdmin"]},
        **{start: (32, sol["treasury"]) for start in prov["immutables"]["treasury"]},
        **{start: (32, hex(sol["maxBatch"])) for start in prov["immutables"]["maxBatch"]},
    }
    for start, (width, value) in expected.items():
        have = int.from_bytes(code[start : start + width], "big")
        if have != int(value, 16):
            raise ctx.fail(f"runtime bytes at {start} = {hex(have)}, expected {value}")
        code[start : start + width] = bytes(width)
    actual = hashlib.sha256(bytes(code)).hexdigest()
    if actual != prov["runtimeSha256"]:
        raise ctx.fail(
            f"runtime sha256 (links and immutables zeroed) = {actual}, provenance.json records {prov['runtimeSha256']}"
        )


def verify(ctx: Context, action: str) -> None:
    sol = ctx.manifest.get("armadaSol")
    if not sol:
        raise ctx.fail("no armadaSol recorded; run without --verify-only first")
    _check_code(ctx, sol, _provenance())

    mismatches = []
    for n, m in _TESTING_ARTIFACT_CONFIGS:
        stored = _stored_vk(ctx, sol["pool"], n, m)
        sepolia = ctx.cast(
            "call", _SEPOLIA_POOL, "getVerificationKey(uint256,uint256)", str(n), str(m), chain="sepolia"
        )
        equal = stored.lower() == sepolia.lower()
        print(f"armada_sol vk ({n},{m}): {'EQUAL' if equal else 'MISMATCH'}")
        if not equal:
            mismatches.append((n, m))
    if mismatches:
        raise ctx.fail(f"stored verification keys differ from Sepolia demo3 pool for shapes: {mismatches}")
