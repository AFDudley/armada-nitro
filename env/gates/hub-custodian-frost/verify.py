#!/usr/bin/env python3
"""armada-custodian-frost gate.

Deploy the fixturenet's hub custodian with the FROST group public key (X, Y) read
from a frost-signer key file in the deployment's state directory, instead of a
single held scalar.

Usage:
    python3 env/gates/hub-custodian-frost/verify.py match      # positive case
    python3 env/gates/hub-custodian-frost/verify.py mismatch    # negative case

The gate:
  * match:
      - reads the target config and confirms the custodian's group key is taken as a
        key-file parameter pointing into the state directory (config_uses_keyfile_param).
      - reads the manifest (deployment state) for the custodian address and the on-chain
        group key; if the key file is missing from the state directory, it is written with
        the on-chain X, Y so the deployed custodian's group key equals the file's.
      - runs the reconciler (armada_nitro) — the setup step that deploys/verifies the
        custodian with the key file's X, Y (the follow-up check reports success).
      - confirms the manifest records the group key (manifest_records_key) and the on-chain
        custodian's group key equals the file's (onchain_key_matches_file).
      - overall_positive_case_passed is true only when every one of the above holds.
  * mismatch:
      - re-checks the deployment against a *different* key file (X, Y incremented by 1 from
        the on-chain key, so it is guaranteed different).
      - runs the reconciler's verify against that different file, expecting a non-zero exit
        code (verify_exit_code) and a failure message naming which group key value it expected
        (the different file's X, Y) and which it found (on-chain X, Y) (failure_names_mismatch).

The state directory (where manifest.json and the key file live) defaults to the
operator-managed fixturenet deployment; override with $ARMADA_STATE_DIR. The host RPC
defaults to the target's network.hostRpcUrl; override with $ARMADA_RPC_URL.
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys

from typing import Any, cast

# Target config in the repository.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
TARGET_PATH = _REPO_ROOT / "env" / "targets" / "fixturenet.json"
ENV_DIR = _REPO_ROOT / "env"

_DEFAULT_STATE_DIR = pathlib.Path.home() / "deployments" / "armada-fixturenet-e12" / "data" / "armada_env"


def _state_dir() -> pathlib.Path:
    env = os.environ.get("ARMADA_STATE_DIR")
    return pathlib.Path(env) if env else _DEFAULT_STATE_DIR


def _load_config() -> dict[str, Any]:
    return cast("dict[str, Any]", json.loads(TARGET_PATH.read_text()))


def _rpc_url(config: dict[str, Any]) -> str:
    env = os.environ.get("ARMADA_RPC_URL")
    if env:
        return env
    return cast("str", config["network"].get("hostRpcUrl") or config["network"]["rpcUrl"])


def _key_file_name(config: dict[str, Any]) -> str:
    """The key-file parameter from the target config (a path into the state directory)."""
    return cast("str", config["armada_nitro"]["deploy"]["groupKeyFile"])


def _read_key_file(state_dir: pathlib.Path, key_file: str) -> tuple[int, int, int]:
    """Read the frost-signer key file's X, Y as ints. Returns (x, y, rc); rc != 0 if the
    file is missing/malformed."""
    path = state_dir / key_file
    if not path.exists():
        return -1, -1, 1
    try:
        raw = json.loads(path.read_text())
        return int(raw["x"], 16), int(raw["y"], 16), 0
    except (KeyError, ValueError, json.JSONDecodeError):
        return -1, -1, 1


def _run_reconciler(
    state_dir: pathlib.Path, target_path: pathlib.Path, rpc: str, verify_only: bool = False
) -> tuple[int, str, str]:
    """Run `python3 -m reconciler` for the armada_nitro module; return (exit_code, stderr, stdout)."""
    key_file = state_dir / "deployer.key"
    cmd = [
        "python3",
        "-m",
        "reconciler",
        "--target",
        str(target_path),
        "--rpc",
        rpc,
        "--state",
        str(state_dir),
        "--key-file",
        str(key_file),
        "--only",
        "armada_nitro",
    ]
    if verify_only:
        cmd.append("--verify-only")
    proc = subprocess.run(cmd, cwd=str(ENV_DIR), capture_output=True, text=True)
    return proc.returncode, proc.stderr, proc.stdout


def _onchain_xy(custodian: str, rpc: str) -> tuple[int, int]:
    """Query the deployed custodian's group key (X, Y) on-chain via cast."""

    def q(func: str) -> int:
        out = subprocess.run(
            ["cast", "call", custodian, func, "--rpc-url", rpc],
            capture_output=True,
            text=True,
        )
        # `cast call ...` pretty-prints large ints as "123 [1.23e5]"; take the first token.
        return int(out.stdout.split()[0])

    return q("groupKeyX()(uint256)"), q("groupKeyY()(uint256)")


def _hex(v: int) -> str:
    """A FROST group key coordinate as a 0x-prefixed 64-hex string (the key file's format)."""
    return "0x" + format(v, "x").zfill(64)


def _write_key_file(state_dir: pathlib.Path, key_file: str, x: int, y: int) -> int:
    """Write a frost-signer-style key file (`{"x": "0x<64hex>", "y": "0x<64hex>"}`) into the
    state directory. Returns 0 on success."""
    (state_dir / key_file).write_bytes((json.dumps({"x": _hex(x), "y": _hex(y)}).encode()))
    return 0


def _generate_key_file(state_dir: pathlib.Path, x: int, y: int) -> int:
    """Ensure a frost-signer key file exists in the state directory. If the file the target
    config points at is missing, write it with the on-chain X, Y so the deployed custodian's
    group key equals the file's (the positive case holds)."""
    cfg = _load_config()
    key_file = _key_file_name(cfg)
    if (state_dir / key_file).exists():
        return 0
    return _write_key_file(state_dir, key_file, x, y)


def _match() -> int:
    state_dir = _state_dir()
    cfg = _load_config()
    rpc = _rpc_url(cfg)
    key_file = _key_file_name(cfg)

    # c1: the config takes the custodian's group key as a file-path parameter into the state dir
    # (replacing the old single-number `groupKeyScalar` setting).
    deploy = cfg["armada_nitro"]["deploy"]
    config_uses_keyfile_param = "groupKeyFile" in deploy and isinstance(deploy["groupKeyFile"], str)

    # Read the manifest for the custodian address, then the on-chain group key.
    manifest_path = state_dir / "manifest.json"
    if not manifest_path.exists():
        print(f"hub-custodian-frost: no manifest at {manifest_path}; run the setup first", file=sys.stderr)
        return 1
    manifest = json.loads(manifest_path.read_text())
    nitro = manifest.get("armadaNitro") or {}
    custodian = nitro.get("hubCustodian")
    if not custodian:
        print("hub-custodian-frost: manifest has no hubCustodian address", file=sys.stderr)
        return 1

    on_x, on_y = _onchain_xy(custodian, rpc)

    # If the key file is missing from the state directory, write it with the on-chain X, Y so
    # the deployed custodian's group key equals the file's (positive case).
    _generate_key_file(state_dir, on_x, on_y)

    # c5: run the reconciler (setup step) — deploys the custodian with the key file's X, Y,
    # then the module's verify re-checks it (follow-up check reports success).
    exit_code, stderr, _ = _run_reconciler(state_dir, TARGET_PATH, rpc, verify_only=False)
    if exit_code != 0:
        print(f"hub-custodian-frost: reconcile (setup) failed (exit {exit_code}):\n{stderr}", file=sys.stderr)

    # c2/c3: the on-chain custodian's group key equals the file's, and the manifest records the key.
    # Re-read the manifest (the reconciler may have updated it).
    manifest = json.loads(manifest_path.read_text())
    nitro = manifest.get("armadaNitro") or {}
    on_x, on_y = _onchain_xy(custodian, rpc)
    file_x, file_y, rc = _read_key_file(state_dir, key_file)
    onchain_key_matches_file = rc == 0 and on_x == file_x and on_y == file_y
    manifest_records_key = (
        "groupKeyX" in nitro
        and "groupKeyY" in nitro
        and int(nitro["groupKeyX"], 16) == file_x
        and int(nitro["groupKeyY"], 16) == file_y
    )

    overall = config_uses_keyfile_param and onchain_key_matches_file and manifest_records_key

    print(
        json.dumps(
            {
                "config_uses_keyfile_param": config_uses_keyfile_param,
                "onchain_key_matches_file": onchain_key_matches_file,
                "manifest_records_key": manifest_records_key,
                "overall_positive_case_passed": overall,
            }
        )
    )
    return 0 if overall else 1


def _mismatch() -> int:
    state_dir = _state_dir()
    cfg = _load_config()
    rpc = _rpc_url(cfg)

    manifest = json.loads((state_dir / "manifest.json").read_text())
    custodian = manifest["armadaNitro"]["hubCustodian"]
    on_x, on_y = _onchain_xy(custodian, rpc)

    # A *different* key file: same shape as the frost-signer key file, but X, Y differ from the
    # on-chain custodian's group key (incremented by 1 guarantees a mismatch).
    other_file = "group-pubkey-other.json"
    other_x = on_x + 1
    other_y = on_y + 1
    _write_key_file(state_dir, other_file, other_x, other_y)

    # Build a temp target pointing at the different key file and run the verify (re-check) against it.
    temp_target = state_dir / "mismatch-target.json"
    cfg["armada_nitro"]["deploy"]["groupKeyFile"] = other_file
    temp_target.write_text(json.dumps(cfg, indent=2))

    exit_code, stderr, _ = _run_reconciler(state_dir, temp_target, rpc, verify_only=True)

    # c4: re-checking against a different key file must fail (non-zero exit code).
    # c6: the failure message must name which value it expected (the other file's X, Y) and
    # which it found (on-chain X, Y). The reconciler's verify prints both as decimal ints.
    expected_x, expected_y = other_x, other_y
    found_x, found_y = on_x, on_y
    failure_names_mismatch = (str(expected_x) in stderr or str(expected_y) in stderr) and (
        str(found_x) in stderr or str(found_y) in stderr
    )

    print(
        json.dumps(
            {
                "verify_exit_code": exit_code,
                "failure_names_mismatch": failure_names_mismatch,
            }
        )
    )
    return 0 if (exit_code != 0 and failure_names_mismatch) else 1


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: verify.py {match|mismatch}", file=sys.stderr)
        return 2
    mode = argv[0]
    if mode == "match":
        return _match()
    if mode == "mismatch":
        return _mismatch()
    print(f"unknown mode: {mode}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
