#!/usr/bin/env python3
"""Behavior check: the adopt-target tool refuses a manifest missing a module.

Usage:
    python3 env/reconciler/tests/check_missing_module_error.py <manifest.json> <out.json>

Runs env/reconciler/tools/adopt_target.py against a manifest that lacks the lido
module, then reports what the tool did as a single JSON object on stdout:

    {"child_exit_code": <int>,          # the tool's exit code (non-zero on refusal)
     "out_file_exists": <bool>,         # whether the tool wrote the output file
     "stderr_mentions_lido": <bool>}    # whether its error names the missing module

The output file is removed before the run so ``out_file_exists`` reflects only what
the tool itself wrote. This script always exits 0 -- the observations are its output.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

_TOOL = Path(__file__).resolve().parents[1] / "tools" / "adopt_target.py"


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if len(args) != 2:
        print(
            "usage: check_missing_module_error.py <manifest.json> <out.json>",
            file=sys.stderr,
        )
        return 2

    manifest_path, out_path = args[0], Path(args[1])
    if out_path.exists():
        out_path.unlink()

    proc = subprocess.run(
        [sys.executable, str(_TOOL), manifest_path, str(out_path)],
        capture_output=True,
        text=True,
    )

    result = {
        "child_exit_code": proc.returncode,
        "out_file_exists": out_path.exists(),
        "stderr_mentions_lido": "lido" in proc.stderr.lower(),
    }
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
