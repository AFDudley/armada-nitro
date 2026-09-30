"""Generate an all-adopt-mode reconcile target from a fixturenet deploy manifest.

Usage:
    python3 env/reconciler/tools/adopt_target.py <manifest.json> <out.json>

Reads a reconcile manifest (the JSON produced by a full fixturenet reconcile run),
extracts every module's deployed addresses, and writes a new reconcile target with
all seven modules (weth, usdc, cctp, aave, lido, armada, armada_nitro) set to
``adopt`` mode.

The script prints a single JSON object to stdout on success:
    {"out": "<path written>", "modules": {"weth": {...}, "usdc": {...}, ...}}

Exit non-zero and name the missing module if any of the seven required modules
is absent from the manifest.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any, cast

# `import reconciler.modules._wallet` (used to derive armada_nitro's group-key
# coordinates via `cast wallet`) resolves against ``env/`` -- the same
# ``mypy_path``/PYTHONPATH root the reconciler package lives under. Make the
# tool self-locating so it works from a bare `python3 env/reconciler/tools/
# adopt_target.py` at the repo root with no PYTHONPATH set.
_ENV_ROOT = Path(__file__).resolve().parents[2]
if str(_ENV_ROOT) not in sys.path:
    sys.path.insert(0, str(_ENV_ROOT))

# The seven modules this tool must include in the target, in dependency order.
_REQUIRED_MODULES = (
    "weth",
    "usdc",
    "cctp",
    "aave",
    "lido",
    "armada",
    "armada_nitro",
)

# Per target module: the ordered adopt fields to write, each as a triple
# ``(out_field, manifest_key, source_field)`` -- the tool reads
# ``manifest[manifest_key][source_field]`` and writes it under ``out_field`` in
# that module's adopt entry. This is the E8 adopt shape (docs/tasks/E8-sepolia.md)
# for each module; addresses are carried from the manifest unchanged.
_MODULE_FIELDS: dict[str, list[tuple[str, str, str]]] = {
    "weth": [
        ("address", "assets", "weth"),
    ],
    "usdc": [
        ("proxy", "usdc", "proxy"),
        ("implementation", "usdc", "implementation"),
        ("masterMinter", "usdc", "masterMinter"),
    ],
    "cctp": [
        ("tokenMessenger", "cctp", "tokenMessenger"),
        ("messageTransmitter", "cctp", "messageTransmitter"),
        ("tokenMinter", "cctp", "tokenMinter"),
        ("domain", "cctp", "domain"),
    ],
    "aave": [
        ("poolAddressesProvider", "aave", "poolAddressesProvider"),
        ("pool", "aave", "pool"),
        ("aUSDC", "aave", "aUSDC"),
        ("stataTokenFactory", "aave", "stataTokenFactory"),
        ("usdcPriceFeed", "aave", "usdcPriceFeed"),
        ("waUSDC", "assets", "waUSDC"),
    ],
    "lido": [
        ("locator", "lido", "locator"),
        ("stETH", "lido", "stETH"),
        ("wstETH", "lido", "wstETH"),
        ("accountingOracle", "lido", "accountingOracle"),
        ("hashConsensus", "lido", "hashConsensus"),
    ],
    "armada": [
        ("pool", "armada", "pool"),
        ("usdc", "armada", "usdc"),
        ("deployBlock", "armada", "deployBlock"),
    ],
    "armada_nitro": [
        ("adjudicator", "armadaNitro", "adjudicator"),
        ("consensusApp", "armadaNitro", "consensusApp"),
        ("hubCustodian", "armadaNitro", "hubCustodian"),
    ],
}

# Optional adopt fields: carried through when the manifest records them, omitted
# when it does not. A full deploy manifest records armada_nitro's group-key scalar
# and revocation delay (the E8 verify shape); a lighter fixturenet manifest that
# only recorded the three custodian addresses is still a valid input.
_MODULE_OPTIONAL_FIELDS: dict[str, list[tuple[str, str, str]]] = {
    "armada_nitro": [
        ("revocationDelay", "armadaNitro", "revocationDelay"),
        ("groupKeyScalar", "armadaNitro", "groupKeyScalar"),
    ],
}


def _read_manifest(path: Path) -> dict[str, Any]:
    """Read and return the JSON manifest at *path*."""
    text = path.read_text(encoding="utf-8")
    return cast("dict[str, Any]", json.loads(text))


def _derive_group_key(scalar: str) -> tuple[str, str]:
    """The secp256k1 public-key X/Y coordinates for a private scalar, derived the
    same way env/reconciler/modules/armada_nitro.py's adopt-verify does -- via
    ``cast wallet public-key`` (reconciler.modules._wallet.public_key_xy)."""
    from reconciler.modules._wallet import public_key_xy

    return public_key_xy(scalar)


def _build_adopt_entry(module_name: str, manifest: dict[str, Any]) -> dict[str, Any]:
    """Build the adopt entry for one module from a manifest.

    Args:
        module_name: The target key (e.g. ``"weth"``).
        manifest: The full manifest dict.

    Returns:
        The adopt dict for *module_name*, with keys matching what the module's
        ``apply()`` reads under ``mode == "adopt"`` and its E8 adopt shape.

    Raises:
        ValueError: If a required key is missing from the manifest. The message
            names the module.
    """
    result: dict[str, Any] = {}
    for out_field, manifest_key, source_field in _MODULE_FIELDS[module_name]:
        section = manifest.get(manifest_key)
        if not isinstance(section, dict) or section.get(source_field) is None:
            raise ValueError(
                f"module {module_name}: missing required key manifest.{manifest_key}.{source_field}"
            )
        result[out_field] = section[source_field]

    for out_field, manifest_key, source_field in _MODULE_OPTIONAL_FIELDS.get(module_name, []):
        section = manifest.get(manifest_key)
        if isinstance(section, dict) and section.get(source_field) is not None:
            result[out_field] = section[source_field]

    # armada_nitro records a plain group-key scalar in a full deploy manifest; the
    # target carries the derived X/Y coordinates the custodian exposes and
    # adopt-verify reads, exactly as env/reconciler/modules/armada_nitro.py derives
    # them. A lighter manifest without the scalar simply omits these.
    if module_name == "armada_nitro" and "groupKeyScalar" in result:
        scalar = result.pop("groupKeyScalar")
        group_key_x, group_key_y = _derive_group_key(scalar)
        result["groupKeyX"] = group_key_x
        result["groupKeyY"] = group_key_y

    return result


def build_adopt_target(manifest: dict[str, Any]) -> dict[str, Any]:
    """Build an all-adopt-mode target from a manifest.

    Args:
        manifest: A full fixturenet deploy manifest.

    Returns:
        A target dict with ``network`` and all seven modules in adopt mode.

    Raises:
        SystemExit: If any of the seven required modules is missing from the
            manifest. The message names the missing module(s).
    """
    target: dict[str, Any] = {"network": manifest.get("network", {})}
    missing: list[str] = []

    for module_name in _REQUIRED_MODULES:
        try:
            adopt_entry = _build_adopt_entry(module_name, manifest)
        except ValueError as e:
            missing.append(str(e))
            continue
        target[module_name] = {"adopt": adopt_entry}

    if missing:
        sys.exit("adopt_target: manifest missing required module(s):\n  " + "\n  ".join(missing))

    return target


def main(argv: list[str] | None = None) -> int:
    """Run the adopt-target generator.

    Usage: ``python3 env/reconciler/tools/adopt_target.py <manifest.json> <out.json>``

    On success prints a single JSON object to stdout:
        {"out": "<path written>", "modules": {"weth": {...}, ...}}

    Returns 0 on success; exits non-zero on failure.
    """
    if argv is None:
        argv = sys.argv[1:]

    if len(argv) != 2:
        sys.exit("Usage: python3 env/reconciler/tools/adopt_target.py <manifest.json> <out.json>")

    manifest_path = Path(argv[0])
    out_path = Path(argv[1])

    if not manifest_path.exists():
        sys.exit(f"manifest file not found: {manifest_path}")

    manifest = _read_manifest(manifest_path)
    target = build_adopt_target(manifest)

    # Collect the adopt entries for the stdout summary.
    modules_summary: dict[str, Any] = {
        module_name: target[module_name]["adopt"] for module_name in _REQUIRED_MODULES
    }

    # Write the target file atomically.
    tmp_path = out_path.with_name(out_path.name + ".tmp")
    tmp_path.write_text(json.dumps(target, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp_path, out_path)

    # Print success JSON to stdout.
    success = {
        "out": str(out_path),
        "modules": modules_summary,
    }
    print(json.dumps(success))
    return 0


if __name__ == "__main__":
    sys.exit(main())
