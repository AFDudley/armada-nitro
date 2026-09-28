#!/usr/bin/env python3
"""Metamorphic conservation check that the committed adopt target is byte-identical
to what the tool regenerates from the committed sample manifest.

Usage:
    python3 env/reconciler/tests/check_golden_regeneration.py <manifest.json> <target.json>

Regenerates the adopt target from the manifest using env/reconciler/tools/adopt_target.py
(the exact bytes it would write) and compares them against the committed target file.
It emits a conservation measurement: ``+enc(regenerated_bytes)`` against
``-enc(committed_bytes)``. The two cancel exactly when the committed file is what the
tool produces, so ``sum(flows) == 0`` is the law "no person hand-edited the target".

Prints ``{"flows": [...]}`` and exits 0.
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


def _enc(text: str) -> int:
    return int.from_bytes(hashlib.sha256(text.encode("utf-8")).digest()[:8], "big")


def _regenerate(manifest_path: Path) -> str:
    """The exact bytes env/reconciler/tools/adopt_target.py writes for this manifest."""
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    target = adopt_target.build_adopt_target(manifest)
    return json.dumps(target, indent=2, sort_keys=True) + "\n"


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if len(args) != 2:
        print(
            "usage: check_golden_regeneration.py <manifest.json> <target.json>",
            file=sys.stderr,
        )
        return 2

    regenerated = _regenerate(Path(args[0]))
    committed = Path(args[1]).read_text(encoding="utf-8")

    flows = [_enc(regenerated), -_enc(committed)]
    print(json.dumps({"flows": flows}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
