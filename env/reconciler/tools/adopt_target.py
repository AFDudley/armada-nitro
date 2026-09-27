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
import sys
from pathlib import Path
from typing import Any, cast

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

# Module name in the manifest (key) -> list of required keys for that module.
# These are the source keys the tool reads from the manifest to build the
# adopt entry for each module in the target.
_MODULE_REQUIRED_KEYS: dict[str, list[str]] = {
    # manifest -> target mapping for the manifest key
    "assets": ["weth"],  # -> weth.adopt.address
    "usdc": [  # -> usdc.adopt
        "proxy",
        "implementation",
        "masterMinter",
    ],
    "cctp": [  # -> cctp.adopt
        "tokenMessenger",
        "messageTransmitter",
        "tokenMinter",
        "domain",
    ],
    "aave": [  # -> aave.adopt (waUSDC lives in manifest.assets)
        "poolAddressesProvider",
        "pool",
        "aUSDC",
        "stataTokenFactory",
        "usdcPriceFeed",
    ],
    "lido": [  # -> lido.adopt (wstETH also duplicated in manifest.assets)
        "locator",
        "stETH",
        "wstETH",
        "accountingOracle",
        "hashConsensus",
    ],
    "armada": [  # -> armada.adopt
        "pool",
        "usdc",
        "deployBlock",
    ],
    "armadaNitro": [  # -> armada_nitro.adopt (groupKeyScalar -> groupKeyX/Y)
        "adjudicator",
        "consensusApp",
        "hubCustodian",
        "revocationDelay",
        "groupKeyScalar",
    ],
}

# Module name in target (key) -> source modules in manifest it reads from.
# For modules that pull from more than one manifest key (e.g. aave reads
# from both manifest.aave and manifest.assets.waUSDC), this maps the
# target module name to the list of manifest keys that contribute.
_TARGET_TO_MANIFEST_KEYS: dict[str, list[str]] = {
    "weth": ["assets"],
    "usdc": ["usdc"],
    "cctp": ["cctp"],
    "aave": ["aave", "assets"],
    "lido": ["lido", "assets"],
    "armada": ["armada"],
    "armada_nitro": ["armadaNitro"],
}


def _read_manifest(path: Path) -> dict[str, Any]:
    """Read and return the JSON manifest at *path*."""
    text = path.read_text(encoding="utf-8")
    return cast("dict[str, Any]", json.loads(text))


def _build_adopt_entry(
    module_name: str, manifest: dict[str, Any]
) -> dict[str, Any]:
    """Build the adopt entry for one module from a manifest.

    Args:
        module_name: The target key (e.g. ``"weth"``).
        manifest: The full manifest dict.

    Returns:
        The adopt dict for *module_name*, with keys matching what the
        module's ``apply()`` reads under ``mode == "adopt"``.

    Raises:
        ValueError: If required keys are missing from the manifest.
    """
    manifest_keys = _TARGET_TO_MANIFEST_KEYS[module_name]
    required = _MODULE_REQUIRED_KEYS.get(module_name, [])
    if not required:
        return {}

    result: dict[str, Any] = {}
    for key in required:
        found = False
        for mk in manifest_keys:
            obj = manifest.get(mk)
            if obj is None:
                continue
            val = obj.get(key)
            if val is not None:
                result[key] = val
                found = True
                break
        if not found:
            raise ValueError(
                f"module {module_name}: missing required key {key!r}"
            )

    # Special case: derive groupKeyX / groupKeyY from groupKeyScalar
    # using the same logic as the reconcile module.  We import it here
    # rather than re-implementing: the scalar is recorded in
    # manifest.armadaNitro.groupKeyScalar (produced by a deploy run),
    # and adopt_verify reads params["groupKeyX"] / params["groupKeyY"]
    # directly.  We need the cast CLI to derive them.
    if module_name == "armada_nitro" and "groupKeyScalar" in result:
        group_key_scalar = result.pop("groupKeyScalar")
        # Remove the 0x prefix for cast's --raw-private-key flag.
        scalar_hex = group_key_scalar[2:] if group_key_scalar.startswith(
            "0x"
        ) else group_key_scalar
        try:
            from reconciler.modules._wallet import public_key_xy
        except ImportError:
            # If running outside the reconciler env (e.g. as a standalone
            # script outside the package), we can't derive X/Y.  In that
            # case the manifest must include groupKeyX and groupKeyY
            # directly instead of groupKeyScalar.  Check for them.
            if "groupKeyX" in result and "groupKeyY" in result:
                pass  # Use them directly — manifest already decoded.
            else:
                sys.exit(
                    "adopt_target: groupKeyScalar is present but "
                    "reconciler.modules._wallet is not importable "
                    "(cast CLI not available?).  Include "
                    "groupKeyX and groupKeyY directly in the manifest "
                    "instead of groupKeyScalar."
                )
        else:
            x_hex, y_hex = public_key_xy(scalar_hex)
            result["groupKeyX"] = x_hex
            result["groupKeyY"] = y_hex

    return result


def build_adopt_target(manifest: dict[str, Any]) -> dict[str, Any]:
    """Build an all-adopt-mode target from a manifest.

    Args:
        manifest: A full fixturenet deploy manifest (the output of
            ``python3 -m reconciler --target ... --state ...``).

    Returns:
        A target dict with ``network`` and all seven modules in adopt mode.

    Raises:
        ValueError: If any of the seven required modules is missing from
            the manifest.  The message names the missing module.
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
        sys.exit(
            "adopt_target: manifest missing required module(s):\n  "
            + "\n  ".join(missing)
        )

    return target


def main(argv: list[str] | None = None) -> int:
    """Run the adopt-target generator.

    Usage: ``python3 env/reconciler/tools/adopt_target.py <manifest.json> <out.json>``

    On success prints a single JSON object to stdout:
        {"out": "<path written>", "modules": {"weth": {...}, ...}}

    Returns 0 on success, 1 on failure.
    """
    if argv is None:
        argv = sys.argv[1:]

    if len(argv) != 2:
        sys.exit(
            f"Usage: {argv[0] if argv else 'python3 env/reconciler/tools/adopt_target.py'} "
            "<manifest.json> <out.json>"
        )

    manifest_path = Path(argv[0])
    out_path = Path(argv[1])

    if not manifest_path.exists():
        sys.exit(f"manifest file not found: {manifest_path}")

    manifest = _read_manifest(manifest_path)
    target = build_adopt_target(manifest)

    # Collect the adopt entries for the stdout summary.
    modules_summary: dict[str, Any] = {}
    for module_name in _REQUIRED_MODULES:
        if module_name in target:
            modules_summary[module_name] = target[module_name]["adopt"]

    # Write the target file atomically (same pattern as _write_manifest).
    tmp_path = out_path.with_name(out_path.name + ".tmp")
    tmp_path.write_text(
        json.dumps(target, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os_replace(tmp_path, out_path)

    # Print success JSON to stdout.
    success = {
        "out": str(out_path),
        "modules": modules_summary,
    }
    print(json.dumps(success))
    return 0


def os_replace(src: Path, dst: Path) -> None:
    """Atomic file rename (imported here to keep the module dependency
    surface minimal; this is the same pattern as _write_manifest)."""
    import os

    os.replace(src, dst)


if __name__ == "__main__":
    sys.exit(main())
