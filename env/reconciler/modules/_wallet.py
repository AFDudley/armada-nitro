"""Shared helper for reconciler modules that need offline `cast wallet` derivations
(addresses, private keys, and secp256k1 public-key coordinates) from the fixturenet's
public anvil/hardhat mnemonic. Purely local computation -- no RPC, no chain, no gas.

Not a reconciler module itself: the leading underscore keeps
`importlib.import_module(f"reconciler.modules.{name}")` (env/reconciler/__main__.py,
driven by MODULE_ORDER) from ever loading this as one (mirrors _forge.py).
"""

from __future__ import annotations

import subprocess

from reconciler.context import CastError

# docs/ENVIRONMENT.md §2: the fixturenet premines accounts 0-9 of this public mnemonic.
MNEMONIC = "test test test test test test test test test test test junk"


def _run(argv: list[str]) -> str:
    result = subprocess.run(["cast", *argv], capture_output=True, text=True)
    if result.returncode != 0:
        raise CastError(f"cast {' '.join(argv)} failed (exit {result.returncode}): {result.stderr.strip()}")
    return result.stdout.strip()


def address(mnemonic_index: int) -> str:
    """The address of account `mnemonic_index` under the fixturenet's public mnemonic."""
    return _run(["wallet", "address", "--mnemonic", MNEMONIC, "--mnemonic-index", str(mnemonic_index)])


def private_key(mnemonic_index: int) -> str:
    """The private key of account `mnemonic_index` under the fixturenet's public mnemonic."""
    return _run(["wallet", "private-key", "--mnemonic", MNEMONIC, "--mnemonic-index", str(mnemonic_index)])


def public_key_xy(private_key_hex: str) -> tuple[str, str]:
    """The uncompressed secp256k1 public key of `private_key_hex`, split into its 32-byte
    X and Y coordinates (0x-prefixed hex). Mirrors
    stack/container-build/cerc-armada-nitro-foundry/armada-nitro-local's derivation of the
    local FROST group key from a plain scalar (`cast wallet public-key --raw-private-key`,
    then splitting the 64-byte raw result in half)."""
    raw = _run(["wallet", "public-key", "--raw-private-key", private_key_hex])
    x, y = raw[2:66], raw[66:130]
    return f"0x{x}", f"0x{y}"
