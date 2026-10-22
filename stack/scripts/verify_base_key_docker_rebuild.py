#!/usr/bin/env python3
"""Verify stack/scripts/base-key.py gives the same cache key before and after
a local docker image rebuild (arn-0c9 c2).

base-key.py no longer calls `docker image inspect`; every image line is a
pure function of committed sources (a source pin, a build-file digest, or a
committed image ref). This script proves that in the strongest way available
without network access: it builds a real local image twice, under the same
tag base-key.py's docstring names (TOOLCHAIN_TAG), with different content
each time so the local image ID genuinely changes, and shows the cache key
does not move between the two builds.

Usage: verify_base_key_docker_rebuild.py --root <REPO_ROOT>

Prints {"keys_equal": bool, "key_before": <16-hex>, "key_after": <16-hex>,
"image_id_before": <sha256:...>, "image_id_after": <sha256:...>,
"image_id_changed": bool} and exits 0 if the keys are equal AND the image ID
genuinely changed (otherwise the rebuild proved nothing), 1 otherwise.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

TOOLCHAIN_TAG = "cerc/armada-nitro-env-toolchain:local"


def _compute_key(root: str) -> str:
    base_key = Path(__file__).resolve().parent / "base-key.py"
    out = subprocess.run(
        [sys.executable, str(base_key), "--root", root],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        raise SystemExit(f"verify_base_key_docker_rebuild: base-key.py failed:\n{out.stderr}")
    return hashlib.sha256(out.stdout.encode()).hexdigest()[:16]


def _build_toolchain_image(label_value: str) -> str:
    """Build a real local image under TOOLCHAIN_TAG with distinct content, and
    return its local image ID."""
    with tempfile.TemporaryDirectory() as d:
        dockerfile = Path(d) / "Dockerfile"
        dockerfile.write_text(f"FROM scratch\nLABEL rebuild-probe={label_value}\n")
        build = subprocess.run(
            ["docker", "build", "--no-cache", "-t", TOOLCHAIN_TAG, d],
            capture_output=True,
            text=True,
        )
        if build.returncode != 0:
            raise SystemExit(f"verify_base_key_docker_rebuild: docker build failed:\n{build.stderr}")
    inspect = subprocess.run(
        ["docker", "image", "inspect", "-f", "{{.Id}}", TOOLCHAIN_TAG],
        capture_output=True,
        text=True,
    )
    if inspect.returncode != 0:
        raise SystemExit(f"verify_base_key_docker_rebuild: docker inspect failed:\n{inspect.stderr}")
    return inspect.stdout.strip()


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Verify the base cache key is stable across a local image rebuild."
    )
    ap.add_argument("--root", default=".")
    args = ap.parse_args()
    root = str(Path(args.root).resolve())

    image_id_before = _build_toolchain_image("before")
    key_before = _compute_key(root)

    image_id_after = _build_toolchain_image("after")
    key_after = _compute_key(root)

    result = {
        "keys_equal": key_before == key_after,
        "key_before": key_before,
        "key_after": key_after,
        "image_id_before": image_id_before,
        "image_id_after": image_id_after,
        "image_id_changed": image_id_before != image_id_after,
    }
    print(json.dumps(result))
    sys.exit(0 if (result["keys_equal"] and result["image_id_changed"]) else 1)


if __name__ == "__main__":
    main()
