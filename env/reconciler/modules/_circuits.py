"""Shared helper: Armada's circuit build (docs/tasks/E9-operability.md).

`fetch()` downloads the pinned release tarball and its SHA256SUMS over plain HTTPS
(GitHub serves public release assets anonymously, so no `gh` login is needed -- see
armada.py's module docstring for why `gh` itself is unavailable), verifies both against
env/sources.lock.json's `armada-circuits` entry, extracts the tarball, verifies every
extracted file against SHA256SUMS, and leaves a copy of SHA256SUMS next to the extracted
circuits for verify() to use later. It runs once, at image build time
(stack/container-build/cerc-armada-nitro-env/Dockerfile) -- never inside a job.

`verify()` re-checks every extracted file's SHA-256 against that same SHA256SUMS copy.
It never downloads: every reconciler module and gate job that needs the circuits on disk
(armada.py's `_ensure_circuits_fetched`, called from `apply()` and from the
armada-env-verify/armada-nitro-e2e job compose files) calls this instead, since the
circuits are already baked into the image.

Both pull their pins (repo, release tag, tarball SHA-256, SHA256SUMS SHA-256) from the
same `armada-circuits` entry in env/sources.lock.json, so the image build and every job
check against one recorded pin rather than two copies that could drift.

Not a reconciler module itself: the leading underscore keeps
`importlib.import_module(f"reconciler.modules.{name}")` (env/reconciler/__main__.py,
driven by MODULE_ORDER) from ever loading this as one (mirrors _forge.py, _wallet.py).
"""

from __future__ import annotations

import hashlib
import json
import tarfile
import tempfile
import urllib.request
from pathlib import Path

from reconciler.context import CastError

# lib/sdk/armada-artifacts.ts's CIRCUITS_BUILD: resolve(__dirname, '../../..', 'armada-circuits', 'build')
# from /src/armada-poc/lib/sdk -- i.e. a sibling of the armada-poc checkout itself.
CIRCUITS_BUILD_DIR = Path("/src/armada-circuits/build")

# fetch()'s copy of the release's SHA256SUMS, made once at image build time so verify()
# has something to check extracted files against without re-downloading.
_SUMS_FILE = CIRCUITS_BUILD_DIR.parent / "SHA256SUMS"

# env/sources.lock.json, resolved relative to this file so it works both from a repo
# checkout and from the image (/src/armada-nitro/env/reconciler/modules/_circuits.py).
_LOCK_FILE = Path(__file__).resolve().parents[2] / "sources.lock.json"


def _pins() -> dict:
    lock = json.loads(_LOCK_FILE.read_text())
    return lock["armada-circuits"]


def _tarball_name(pins: dict) -> str:
    return f"armada-circuits-{pins['tag']}.tgz"


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _verify_extracted(sums_path: Path, tarball_name: str) -> None:
    for line in sums_path.read_text().splitlines():
        line = line.strip()
        if not line or tarball_name in line:
            continue
        expected, _, rel_path = line.partition("  ")
        file_path = CIRCUITS_BUILD_DIR / rel_path
        if not file_path.is_file():
            raise CastError(f"{rel_path} missing under {CIRCUITS_BUILD_DIR}")
        actual = _sha256_file(file_path)
        if actual != expected:
            raise CastError(f"{rel_path} sha256 = {actual}, expected {expected}")


def fetch() -> None:
    """Download, verify, and extract the pinned circuit build. Image-build-time only."""
    pins = _pins()
    tarball_name = _tarball_name(pins)
    base_url = f"https://github.com/{pins['repo']}/releases/download/{pins['tag']}"

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        tarball_path = tmp_path / tarball_name
        sums_path = tmp_path / "SHA256SUMS"
        urllib.request.urlretrieve(f"{base_url}/{tarball_name}", tarball_path)
        urllib.request.urlretrieve(f"{base_url}/SHA256SUMS", sums_path)

        actual = _sha256_file(tarball_path)
        if actual != pins["tarballSha256"]:
            raise CastError(f"{tarball_name} sha256 = {actual}, expected {pins['tarballSha256']}")
        actual = _sha256_file(sums_path)
        if actual != pins["sumsFileSha256"]:
            raise CastError(f"SHA256SUMS sha256 = {actual}, expected {pins['sumsFileSha256']}")

        CIRCUITS_BUILD_DIR.mkdir(parents=True, exist_ok=True)
        with tarfile.open(tarball_path) as tar:
            tar.extractall(CIRCUITS_BUILD_DIR)

        # Belt-and-braces, same as the per-file check verify() runs later: the
        # SHA256SUMS lines for the tarball itself, already checked above, refer to the
        # archive, not an extracted file.
        _verify_extracted(sums_path, tarball_name)

        _SUMS_FILE.write_text(sums_path.read_text())


def verify() -> None:
    """Verify the circuits already baked into the image. Never downloads: a missing
    SHA256SUMS copy or a file that fails its hash is a hard failure naming the file and
    both hashes."""
    if not _SUMS_FILE.is_file():
        raise CastError(
            f"{_SUMS_FILE} missing; circuits are expected to be baked into the image "
            "(stack/container-build/cerc-armada-nitro-env/Dockerfile)"
        )
    pins = _pins()
    _verify_extracted(_SUMS_FILE, _tarball_name(pins))
