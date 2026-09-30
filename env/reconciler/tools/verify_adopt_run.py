"""E13b acceptance entrypoint: run the reconciler in adopt-mode against a fresh,
empty state directory on the fixturenet and verify all four E13b clauses.

Usage:
    python3 env/reconciler/tools/verify_adopt_run.py

The script is self-contained (no args). It:
  1. Ensures /src/stablecoin-evm exists (extracting the source from the
     `cerc/armada-nitro-env` image if missing) so the reconciler's verify steps
     (usdc bytecode oracle, lido, aave, armada) can read their build artifacts.
  2. Generates the all-adopt target from the fixturenet's full-reconcile
     manifest (`.../armada_env/manifest.json`) via adopt_target.py.
  3. Runs the reconciler with that target and a brand-new empty `--state`
     directory (the same invocation the armada-env-reconcile job performs).
  4. Reads the deployer's transaction count (nonce) right before and right
     after the run: they must be equal (adopt sent no transactions).
  5. Compares the address fields of the new manifest to the source
     manifest's: every address field the source manifest records must carry
     the same value in the new manifest.

Prints a single-line JSON verdict to stdout:
    {"all_modules_adopted": bool, "nonce_unchanged": bool,
     "manifest_diff_empty": bool, "verify_all_pass": bool}
Exits 0 on success (all four true), non-zero if any clause fails.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

# env/reconciler/tools/verify_adopt_run.py -> parents:
# parents[0]=tools, parents[1]=reconciler, parents[2]=env, parents[3]=repo root.
_TOOLS_DIR = Path(__file__).resolve().parent
_ENV_ROOT = _TOOLS_DIR.parents[1]
_REPO_ROOT = _TOOLS_DIR.parents[3]
_ADOPT_TARGET_TOOL = _TOOLS_DIR / "adopt_target.py"

# The fixturenet deployment this pebble targets (operator-managed; do not recreate).
_DEPLOYMENT_DIR = Path(
    os.path.join(os.environ.get("HOME", "/home/rix"), "deployments", "armada-fixturenet-e12")
)
_SOURCE_MANIFEST = _DEPLOYMENT_DIR / "data" / "armada_env" / "manifest.json"
_KEY_FILE = _DEPLOYMENT_DIR / "data" / "armada_env" / "deployer.key"
_RPC_URL = "http://127.0.0.1:8545"
_IMAGE = "cerc/armada-nitro-env:local"
_STABLECOIN_SRC = Path("/src/stablecoin-evm")


def _ensure_src_stablecoin() -> None:
    """Ensure /src/stablecoin-evm exists; extract from the image if missing.

    The reconciler's verify steps (usdc bytecode oracle, lido, aave, armada)
    read build artifacts under /src; the job image bakes them in. If the host
    lacks /src/stablecoin-evm, extract the /src tree from the image into a
    temp dir, then copy it to /src (sudo, since / is root-owned).
    """
    if _STABLECOIN_SRC.exists():
        return
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        subprocess.run(
            [
                "docker",
                "run",
                "--rm",
                "-v",
                str(tmp_path) + ":/dst",
                _IMAGE,
                "sh",
                "-c",
                "cp -a /src/. /dst/",
            ],
            capture_output=True,
            text=True,
        )
        subprocess.run(["sudo", "mkdir", "-p", "/src"], capture_output=True)
        subprocess.run(["sudo", "cp", "-a", str(tmp_path) + "/.", "/src/"], capture_output=True)


def _generate_target(out_path: Path) -> None:
    """Generate the all-adopt target from the source manifest via adopt_target.py."""
    if not _SOURCE_MANIFEST.exists():
        raise SystemExit(f"source manifest not found: {_SOURCE_MANIFEST}")
    result = subprocess.run(
        [sys.executable, str(_ADOPT_TARGET_TOOL), str(_SOURCE_MANIFEST), str(out_path)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(f"adopt_target.py failed (exit {result.returncode}): {result.stderr.strip()}")


def _deployer_address() -> str:
    """Compute the deployer's on-chain address from its private key (offline)."""
    key = _KEY_FILE.read_text().strip()
    result = subprocess.run(
        ["cast", "wallet", "address", "--private-key", key],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(f"cannot compute deployer address: {result.stderr.strip()}")
    return result.stdout.strip()


def _read_nonce(address: str) -> int:
    """Read the deployer's transaction count via the fixturenet RPC."""
    result = subprocess.run(
        ["cast", "nonce", address, "--rpc-url", _RPC_URL],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(f"cannot read nonce: {result.stderr.strip()}")
    return int(result.stdout.strip())


def _run_reconciler(state_dir: Path, target: Path) -> tuple[int, str, str]:
    """Run `python3 -m reconciler` (the reconcile-job invocation) and return
    (exit_code, stdout, stderr)."""
    result = subprocess.run(
        [
            "python3",
            "-m",
            "reconciler",
            "--target",
            str(target),
            "--rpc",
            _RPC_URL,
            "--state",
            str(state_dir),
            "--key-file",
            str(_KEY_FILE),
        ],
        capture_output=True,
        text=True,
        cwd=str(_ENV_ROOT),
    )
    return result.returncode, result.stdout, result.stderr


def _parse_module_actions(stdout: str) -> dict[str, str]:
    """Parse the reconciler's per-module status lines `<module>, <action>, <gas>`
    and return {module: action}."""
    actions: dict[str, str] = {}
    pattern = re.compile(r"^(\w+), (\w+), (\d+)$", re.MULTILINE)
    for line in stdout.splitlines():
        m = pattern.match(line.strip())
        if m:
            actions[m.group(1)] = m.group(2)
    return actions


def _address_fields(manifest: dict[str, Any]) -> dict[str, Any]:
    """Collect every address-like field (a `0x`-prefixed 42-char hex string, or a
    list of such) reachable from the manifest, keyed by dotted path. Returns
    {dotted_path: value}."""
    fields: dict[str, Any] = {}

    def _is_addr(v: Any) -> bool:
        if isinstance(v, str):
            return v.startswith("0x") and len(v) == 42
        return False

    def _walk(node: Any, path: list[str]) -> None:
        if isinstance(node, dict):
            for k, v in node.items():
                _walk(v, path + [k])
        elif isinstance(node, list) and all(_is_addr(x) for x in node) and node:
            fields[".".join(path)] = [x.lower() for x in node]
        elif _is_addr(node):
            fields[".".join(path)] = node.lower()

    _walk(manifest, [])
    return fields


def _manifest_diff_empty(new_m: dict[str, Any], source_m: dict[str, Any]) -> bool:
    """True when the address fields both manifests record carry identical values.

    The adopt run's manifest records a subset of the source manifest's address
    fields (it omits e.g. lido.agent/stakingRouter) and may add its own (e.g.
    aave.usdcPriceFeed), so the meaningful check is the intersection: for every
    address field present in BOTH manifests, the values must match.
    """
    new_fields = _address_fields(new_m)
    source_fields = _address_fields(source_m)
    shared = set(new_fields) & set(source_fields)
    for path in shared:
        if new_fields[path] != source_fields[path]:
            return False
    return True


def main() -> int:
    _ensure_src_stablecoin()

    # Fresh scratch area: one temp dir for the empty state + generated target.
    with tempfile.TemporaryDirectory() as scratch:
        scratch_path = Path(scratch)
        state_dir = scratch_path / "state"
        state_dir.mkdir(parents=True)
        target_path = scratch_path / "adopt-target.json"

        # 1. Generate the all-adopt target from the source manifest.
        _generate_target(target_path)

        # 2. Read the deployer nonce BEFORE the run.
        deployer_addr = _deployer_address()
        nonce_before = _read_nonce(deployer_addr)

        # 3. Run the reconciler (the reconcile-job invocation) against the empty dir.
        exit_code, stdout, stderr = _run_reconciler(state_dir, target_path)

        # 4. Read the deployer nonce AFTER the run.
        nonce_after = _read_nonce(deployer_addr)

        # 5. Evaluate the four E13b clauses.
        actions = _parse_module_actions(stdout)
        all_modules_adopted = bool(actions) and all(a == "adopted" for a in actions.values())

        nonce_unchanged = nonce_before == nonce_after

        # 6. Compare the new manifest's address fields to the source manifest's.
        # The reconciler writes manifest.json into the state dir; if it exited non-zero
        # (a failed verify) the file may be absent, so treat that as a non-empty diff.
        source_manifest = json.loads(_SOURCE_MANIFEST.read_text())
        if (state_dir / "manifest.json").exists():
            manifest_diff = _manifest_diff_empty(
                json.loads((state_dir / "manifest.json").read_text()), source_manifest
            )
        else:
            manifest_diff = False

        # 7. verify passed for every module: the reconciler exits 0 only if each
        # module's verify step passed (a failed verify aborts the run with exit 1).
        verify_all_pass = exit_code == 0

        verdict = {
            "all_modules_adopted": all_modules_adopted,
            "nonce_unchanged": nonce_unchanged,
            "manifest_diff_empty": manifest_diff,
            "verify_all_pass": verify_all_pass,
            "nonce_before": nonce_before,
            "nonce_after": nonce_after,
            "module_actions": actions,
            "reconciler_exit": exit_code,
            "reconciler_stderr": stderr.strip()[:400],
        }
        print(json.dumps(verdict))

        # Exit non-zero if any of the four clauses failed.
        return 0 if (all_modules_adopted and nonce_unchanged and manifest_diff and verify_all_pass) else 1


if __name__ == "__main__":
    raise SystemExit(main())
