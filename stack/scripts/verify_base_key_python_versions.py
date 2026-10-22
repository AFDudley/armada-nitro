#!/usr/bin/env python3
"""Verify stack/scripts/base-key.py gives the same cache key under two Python
interpreters (arn-0c9 c1).

base-key.py's AST-digest lines serialise to a canonical recursive value, not
to ast.dump's repr, so the digest does not depend on the host Python version.
The YAML-digest lines need the same pinned PyYAML in every interpreter; this
script installs it for each interpreter named on the command line before it
runs base-key.py.

Usage: verify_base_key_python_versions.py --root <REPO_ROOT> --python-a
<interpreter> --python-b <interpreter>

Prints {"digests_equal": bool, "digest_a": <16-hex>, "digest_b": <16-hex>}
and exits 0 if the two digests are equal, 1 otherwise.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

PINNED_PYYAML = "6.0.1"


def _ensure_pyyaml(interp: str) -> None:
    check = subprocess.run([interp, "-c", "import yaml"], capture_output=True)
    if check.returncode == 0:
        return
    install = subprocess.run(
        [interp, "-m", "pip", "install", "--break-system-packages", f"pyyaml=={PINNED_PYYAML}"],
        capture_output=True,
        text=True,
    )
    if install.returncode != 0:
        raise SystemExit(
            f"verify_base_key_python_versions: failed to install PyYAML for {interp}:\n{install.stderr}"
        )
    recheck = subprocess.run([interp, "-c", "import yaml"], capture_output=True)
    if recheck.returncode != 0:
        raise SystemExit(f"verify_base_key_python_versions: PyYAML still not importable for {interp}")


def _compute_digest(interp: str, root: str) -> str:
    base_key = Path(__file__).resolve().parent / "base-key.py"
    out = subprocess.run(
        [interp, str(base_key), "--root", root],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        raise SystemExit(f"verify_base_key_python_versions: base-key.py failed under {interp}:\n{out.stderr}")
    return hashlib.sha256(out.stdout.encode()).hexdigest()[:16]


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Verify the base cache key is stable across Python interpreters."
    )
    ap.add_argument("--root", default=".")
    ap.add_argument("--python-a", required=True)
    ap.add_argument("--python-b", required=True)
    args = ap.parse_args()

    root = str(Path(args.root).resolve())
    _ensure_pyyaml(args.python_a)
    _ensure_pyyaml(args.python_b)
    digest_a = _compute_digest(args.python_a, root)
    digest_b = _compute_digest(args.python_b, root)

    result = {
        "digests_equal": digest_a == digest_b,
        "digest_a": digest_a,
        "digest_b": digest_b,
    }
    print(json.dumps(result))
    sys.exit(0 if result["digests_equal"] else 1)


if __name__ == "__main__":
    main()
