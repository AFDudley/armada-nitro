"""Reconciler framework entry point.

    python3 -m reconciler --target <file> --rpc <url> --state <dir> [--only <module>] [--verify-only]

Loads the target (desired state) and, if present, `<state>/manifest.json`.
Runs the modules the target names, in the fixed dependency order below. For
each module: observe, apply (skipped with --verify-only), verify. The
manifest is rewritten atomically (temp file, then rename) after every
module that completes -- keys are sorted, so an unchanged state gives a
byte-identical file, and a failure partway through a multi-module target
still durably records the modules that finished.

The deployer key comes from --key-file or $DEPLOYER_KEY_FILE, never from
the target file.
"""
from __future__ import annotations

import argparse
import importlib
import json
import os
import sys
from pathlib import Path

from reconciler.context import CastError, Context, ReconcileError

# Fixed dependency order (docs/ENVIRONMENT.md §4). A target names a subset;
# modules it does not name are simply not run.
MODULE_ORDER = [
    "weth",
    "usdc",
    "cctp",
    "aave",
    "lido",
    "armada",
    "armada_nitro",
    "funding",
]


def _load_target(path: Path) -> dict:
    target = json.loads(path.read_text())
    unknown = sorted(name for name in target if name != "network" and name not in MODULE_ORDER)
    if unknown:
        sys.exit(f"reconciler: target {path} names unknown module(s): {', '.join(unknown)}")
    return target


def _load_manifest(state_dir: Path, target: dict) -> dict:
    manifest_path = state_dir / "manifest.json"
    if manifest_path.exists():
        return json.loads(manifest_path.read_text())
    return {
        "network": target.get("network", {}),
        "assets": {},
        "sources": {},
        "gasUsed": {},
    }


def _write_manifest(state_dir: Path, manifest: dict) -> None:
    manifest_path = state_dir / "manifest.json"
    tmp_path = manifest_path.with_name(manifest_path.name + ".tmp")
    tmp_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    os.replace(tmp_path, manifest_path)


def _module_run_order(target: dict, only: str | None) -> list[str]:
    named = [name for name in target if name != "network"]
    if only is None:
        return [name for name in MODULE_ORDER if name in named]
    if only not in named:
        sys.exit(f"reconciler: --only {only!r} is not named in the target")
    return [only]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python3 -m reconciler")
    parser.add_argument("--target", required=True, type=Path)
    parser.add_argument("--rpc", required=True, dest="rpc_url")
    parser.add_argument("--state", required=True, type=Path, dest="state_dir")
    parser.add_argument("--only", default=None)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument(
        "--key-file",
        type=Path,
        default=None,
        help="deployer private-key file (default: $DEPLOYER_KEY_FILE)",
    )
    args = parser.parse_args(argv)

    key_file = args.key_file
    if key_file is None:
        env_key_file = os.environ.get("DEPLOYER_KEY_FILE")
        if not env_key_file:
            parser.error("--key-file or $DEPLOYER_KEY_FILE is required")
        key_file = Path(env_key_file)
    if not key_file.exists():
        parser.error(f"key file {key_file} does not exist")

    args.state_dir.mkdir(parents=True, exist_ok=True)

    target = _load_target(args.target)
    manifest = _load_manifest(args.state_dir, target)
    run_order = _module_run_order(target, args.only)

    for module_name in run_order:
        module = importlib.import_module(f"reconciler.modules.{module_name}")
        ctx = Context(
            rpc_url=args.rpc_url,
            state_dir=args.state_dir,
            key_file=key_file,
            target=target,
            manifest=manifest,
            verify_only=args.verify_only,
            module_name=module_name,
        )
        try:
            if args.verify_only:
                module.observe(ctx)
                action, gas_used = "present", 0
            else:
                observed = module.observe(ctx)
                action, gas_used = module.apply(ctx, observed)
                # Record what apply() did before verify() can fail: a crash after a broadcast must not
                # lose the addresses, or the next run would deploy again.
                _write_manifest(args.state_dir, manifest)
            module.verify(ctx, action)
        except ReconcileError as e:
            print(f"reconciler: FAILED: {module_name}: {e.postcondition}", file=sys.stderr)
            return 1
        except CastError as e:
            print(f"reconciler: FAILED: {module_name}: {e}", file=sys.stderr)
            return 1

        print(f"{module_name}, {action}, {gas_used}")
        _write_manifest(args.state_dir, manifest)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
