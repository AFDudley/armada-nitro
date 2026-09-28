#!/usr/bin/env python3
"""Metamorphic conservation check for the lido adopt entry's relaxed-postcondition
address fields.

Usage:
    python3 env/reconciler/tests/check_lido_relaxed_fields.py <manifest.json>

E8's relaxed lido postcondition reads two addresses off the adopt entry: the
``stETH()`` link and the ``stEthPerToken()`` source, i.e. ``stETH`` and ``wstETH``.
This check builds the adopt target and emits a conservation measurement pairing each
of those two target fields against its manifest source; ``sum(flows) == 0`` holds
exactly when both are present and carried through unchanged.

Prints ``{"flows": [...]}`` and exits 0 on success; a missing/absent field exits
non-zero (the relaxed postcondition could not be satisfied).
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

_RELAXED_FIELDS = ("stETH", "wstETH")


def _enc(value: object) -> int:
    blob = json.dumps(value, sort_keys=True).encode("utf-8")
    return int.from_bytes(hashlib.sha256(blob).digest()[:5], "big")


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if len(args) != 1:
        print("usage: check_lido_relaxed_fields.py <manifest.json>", file=sys.stderr)
        return 2

    manifest = json.loads(Path(args[0]).read_text(encoding="utf-8"))
    target = adopt_target.build_adopt_target(manifest)
    lido_adopt = target["lido"]["adopt"]
    lido_manifest = manifest["lido"]

    flows: list[int] = []
    for field in _RELAXED_FIELDS:
        target_value = lido_adopt.get(field)
        source_value = lido_manifest.get(field)
        if not target_value or not source_value:
            print(
                f"lido adopt entry is missing relaxed-postcondition field {field!r}",
                file=sys.stderr,
            )
            return 1
        flows.append(_enc(source_value))
        flows.append(-_enc(target_value))

    print(json.dumps({"flows": flows}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
