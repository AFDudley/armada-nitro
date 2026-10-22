#!/usr/bin/env python3
"""arn-578: gate every non-test contract a deploy script deploys at 24,576 bytes runtime (EIP-170).

The check parses the `forge build --sizes` report itself; it does not rely only on
`forge build --sizes`'s own exit code. It fails when a contract that a deploy script
under `script/` deploys has a runtime size above 24,576 bytes. Test harnesses no deploy
script deploys (e.g. AdjudicatorHarness) are out of scope and do not fail the check.

    python3 scripts/check-contract-sizes.py --report -
    python3 scripts/check-contract-sizes.py --report <path>
    python3 scripts/check-contract-sizes.py            # runs forge build --sizes itself

Exits 0 only when every deployed contract is at or below 24,576 bytes runtime.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys

_LIMIT_BYTES = 24576  # EIP-170
_STDOUT = "python3"
_JSON_FIELDS = ("oversized_count", "oversized")

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]


def _parse_report(text: str) -> list[tuple[str, int]]:
    """Parse a forge build --sizes table.

    Handles both the real forge output (box-drawn, `+` separators) and the simplified
    table the acceptance tests feed via stdin. A data row is `| <contract> | <runtime> |
    ...` where the first data column is the contract name and the second is its runtime size.
    Returns (contract_name, runtime_size_bytes) for every data row.
    """
    rows = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        parts = stripped.split("|")
        # parts[0] and parts[-1] are empty (before first |, after last |).
        # parts[1] = contract name, parts[2] = runtime size.
        if len(parts) < 3:
            continue
        contract = parts[1].strip()
        size_field = parts[2].strip()
        try:
            size = int(size_field.replace(",", ""))
        except (ValueError, IndexError):
            # header row (Contract / Runtime Size (B)) or separator -- not a data row.
            continue
        if contract == "Contract" or contract == "---" or contract.startswith("---"):
            continue
        rows.append((contract, size))
    return rows


def _deployed_contracts(repo_root: pathlib.Path) -> set[str]:
    """Contracts a top-level deploy script under script/ actually deploys.

    Scans `script/*.s.sol` (not `script/helpers/`) for `new <Contract>` and
    `deployCode('<file>:<Contract>')` markers. Test harnesses (AdjudicatorHarness) live
    elsewhere and are not deployed by any deploy script, so they are excluded.
    """
    script_dir = repo_root / "script"
    names: set[str] = set()
    if not script_dir.is_dir():
        return names
    for f in script_dir.glob("*.s.sol"):
        text = f.read_text(encoding="utf-8", errors="replace")
        # `new <Name>` -- the identifier after `new` is a contract when it's a known report
        # contract; bare types (address, string, bytes) are filtered later by intersection.
        for m in re.finditer(r"\bnew\s+([A-Za-z_]\w*)\b", text):
            names.add(m.group(1))
        # deployCode('<file>:<Name>'
        for m in re.finditer(r"deployCode\(\s*'[^']*:([A-Za-z_]\w*)'", text):
            names.add(m.group(1))
    return names


def _read_report(report_arg: str | None) -> str:
    """Resolve the report text from the --report argument (stdin, file, or forge run)."""
    if report_arg is None:
        result = subprocess.run(
            ["forge", "build", "--sizes"],
            cwd=str(_REPO_ROOT),
            capture_output=True,
            text=True,
        )
        # route forge's stdout+stderr to the script's stderr so stdout stays clean JSON
        if result.stdout:
            sys.stderr.write(result.stdout)
        if result.stderr:
            sys.stderr.write(result.stderr)
        return result.stdout
    if report_arg == "-":
        return sys.stdin.read()
    return pathlib.Path(report_arg).read_text(encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description="EIP-170 contract size gate (24,576 bytes runtime)")
    parser.add_argument(
        "--report",
        default=None,
        help="Report source: '-' for stdin, a file path, or omit to run `forge build --sizes`",
    )
    args = parser.parse_args()

    deployed = _deployed_contracts(_REPO_ROOT)
    report_text = _read_report(args.report)
    rows = _parse_report(report_text)

    oversized = []
    for contract, runtime in rows:
        if contract in deployed and runtime > _LIMIT_BYTES:
            oversized.append({"contract": contract, "runtime": runtime})

    oversized_count = len(oversized)
    result = {
        "oversized_count": oversized_count,
        "oversized": oversized,
        "limit_bytes": _LIMIT_BYTES,
        "deployed_count": len(deployed),
    }
    print(json.dumps(result))
    if oversized_count > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
