#!/usr/bin/env python3
"""arn-274 (R1.4): every contract the deploy script deploys fits the EIP-170 runtime limit.

Resolves the set of contracts `--script` actually deploys: the top-level `new <Contract>(...)`
and `deployCode('<file>:<Contract>', ...)` targets in the script, plus every external library
each of those contracts references (via its compiled artifact's `bytecode.linkReferences`) --
those libraries are deployed and linked automatically by `forge script --broadcast`, so they
belong in the deployed set even though the script never names them directly (R1 brief,
component (d)). Matches that set against `forge build --sizes --json`'s runtime sizes and fails
if any deployed contract exceeds `--limit` bytes.

    python3 scripts/check-deployed-contract-sizes.py --script script/Deploy.s.sol --limit 24576

Prints one JSON line: {"deployed_contract_count", "over_limit_count", "max_runtime_size",
"deployed", "limit"}. Exits 0 only when every deployed contract is at or below the limit.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LIMIT = 24576  # EIP-170
_BUILTIN_TYPES = {
    "uint256",
    "address",
    "bytes",
    "bytes32",
    "string",
    "bool",
    "int256",
    "uint8",
    "uint16",
    "uint32",
    "uint64",
    "uint120",
    "uint160",
}


def _top_level_targets(script_path: Path) -> set[str]:
    """Contracts named directly in the script via `new <Contract>` or `deployCode('<f>:<C>')`."""
    text = script_path.read_text(encoding="utf-8", errors="replace")
    names: set[str] = set()
    for m in re.finditer(r"\bnew\s+([A-Za-z_]\w*)\s*\(", text):
        name = m.group(1)
        if name not in _BUILTIN_TYPES:
            names.add(name)
    for m in re.finditer(r"deployCode\(\s*'[^']*:([A-Za-z_]\w*)'", text):
        names.add(m.group(1))
    return names


def _artifact_path(repo_root: Path, contract: str) -> Path | None:
    """Find `out/<Source>.sol/<contract>.json` for a top-level contract name."""
    matches = list(repo_root.glob(f"out/**/{contract}.json"))
    return matches[0] if matches else None


def _linked_libraries(repo_root: Path, contract: str) -> set[str]:
    """Library contract names `contract`'s creation bytecode references (unlinked)."""
    artifact = _artifact_path(repo_root, contract)
    if artifact is None:
        return set()
    data = json.loads(artifact.read_text())
    link_refs = data.get("bytecode", {}).get("linkReferences", {}) or {}
    libs: set[str] = set()
    for _file, entries in link_refs.items():
        libs.update(entries.keys())
    return libs


def _deployed_contracts(repo_root: Path, script_path: Path) -> set[str]:
    """The full deployed set: the script's direct targets plus every library they link."""
    deployed = set(_top_level_targets(script_path))
    frontier = set(deployed)
    while frontier:
        next_frontier: set[str] = set()
        for name in frontier:
            for lib in _linked_libraries(repo_root, name):
                if lib not in deployed:
                    deployed.add(lib)
                    next_frontier.add(lib)
        frontier = next_frontier
    return deployed


def _runtime_sizes(repo_root: Path) -> dict[str, int]:
    """Run `forge build --sizes --json` and return {contract_name: runtime_size_bytes}.

    The first stdout line is the sizes JSON object; later lines are per-diagnostic JSON forge
    also emits in `--json` mode and are ignored here.
    """
    result = subprocess.run(
        ["forge", "build", "--sizes", "--json"],
        cwd=str(repo_root),
        capture_output=True,
        text=True,
        timeout=600,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise RuntimeError(f"forge build --sizes --json failed: exit {result.returncode}")

    for line in result.stdout.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue
        if any(isinstance(v, dict) and "runtime_size" in v for v in data.values()):
            sizes: dict[str, int] = {}
            for name, info in data.items():
                # strip a trailing " (path/to/File.t.sol)" test-harness qualifier, if present,
                # so a bare contract name also matches; keep the qualified key too.
                sizes[name] = int(info["runtime_size"])
                bare = name.split(" (", 1)[0]
                sizes.setdefault(bare, int(info["runtime_size"]))
            return sizes
    raise RuntimeError("forge build --sizes --json: no sizes object found in stdout")


def main() -> None:
    parser = argparse.ArgumentParser(description="Check deployed contract sizes against the EIP-170 limit")
    parser.add_argument("--script", required=True, help="Path to the deploy script")
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT, help="EIP-170 limit in bytes")
    args = parser.parse_args()

    script_path = Path(args.script)
    if not script_path.is_absolute():
        script_path = REPO_ROOT / script_path
    if not script_path.exists():
        print(json.dumps({"error": f"script not found: {script_path}"}))
        sys.exit(1)

    deployed = _deployed_contracts(REPO_ROOT, script_path)
    sizes = _runtime_sizes(REPO_ROOT)

    deployed_contract_count = 0
    over_limit_count = 0
    max_runtime_size = 0
    missing = []
    for contract in sorted(deployed):
        if contract not in sizes:
            missing.append(contract)
            continue
        size = sizes[contract]
        deployed_contract_count += 1
        if size > args.limit:
            over_limit_count += 1
        max_runtime_size = max(max_runtime_size, size)

    result = {
        "deployed_contract_count": deployed_contract_count,
        "over_limit_count": over_limit_count,
        "max_runtime_size": max_runtime_size,
        "deployed": sorted(deployed),
        "missing_from_sizes_report": missing,
        "limit": args.limit,
    }
    print(json.dumps(result))

    if deployed_contract_count < 3 or over_limit_count > 0 or max_runtime_size > args.limit:
        sys.exit(1)


if __name__ == "__main__":
    main()
