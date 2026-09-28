#!/usr/bin/env python3
"""Metamorphic conservation check for the adopt-target generator's addresses.

Usage:
    python3 env/reconciler/tests/check_address_conservation.py <manifest.json>

Builds the adopt target from the manifest (via env/reconciler/tools/adopt_target.py)
and emits a conservation measurement on stdout: for every adopt field the tool
copies from the manifest, a ``+enc(manifest_value)`` inflow and a matching
``-enc(target_value)`` outflow. The two cancel exactly when the tool carried the
address through unchanged, so ``sum(flows) == 0`` is the conservation law "every
address in the target equals its source in the manifest" -- no stored expected
value to forge.

Prints ``{"flows": [...]}`` and exits 0 on success; a structural failure (a
missing module, unreadable manifest) exits non-zero.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

_TOOLS = Path(__file__).resolve().parents[1] / "tools"
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

import adopt_target  # noqa: E402


def _enc(value: object) -> int:
    """A stable 40-bit numeric encoding of a JSON value (address string, number,
    or list) -- equal values encode to the same number, so a conserved flow pair
    cancels to exactly zero under float addition (40 bits << 2**53)."""
    blob = json.dumps(value, sort_keys=True).encode("utf-8")
    return int.from_bytes(hashlib.sha256(blob).digest()[:5], "big")


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if len(args) != 1:
        print("usage: check_address_conservation.py <manifest.json>", file=sys.stderr)
        return 2

    manifest = json.loads(Path(args[0]).read_text(encoding="utf-8"))
    target = adopt_target.build_adopt_target(manifest)

    flows: list[int] = []
    for module_name, fields in adopt_target._MODULE_FIELDS.items():
        adopt = target[module_name]["adopt"]
        for out_field, manifest_key, source_field in fields:
            if out_field not in adopt:
                # A derived field (armada_nitro's groupKeyScalar -> groupKeyX/Y):
                # not a straight carry-through, so not part of this conservation.
                continue
            source_value = manifest[manifest_key][source_field]
            flows.append(_enc(source_value))
            flows.append(-_enc(adopt[out_field]))

    print(json.dumps({"flows": flows}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
