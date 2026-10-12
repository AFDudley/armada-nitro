#!/usr/bin/env
"""Guard: armada-nitro settlement contracts must stay exchange-rate-free (design 15).

Scans src/ArmadaNitroAdjudicator.sol and every src/nitro/**/*.sol for:
  - ERC-4626 imports (any import path containing "4626")
  - calls to the ERC-4626 rate-conversion functions:
    convertToAssets, convertToShares, previewDeposit, previewMint,
    previewRedeem, previewWithdraw

Default run prints JSON:
  {"files_scanned": N, "erc4626_imports": [...], "rate_calls": [...]}

With --self-test, writes a temp .sol file containing "convertToAssets(",
scans it with the same scanner, and prints {"self_test_detected": ...}.
"""

import json
import os
import re
import sys
import tempfile

RATE_FUNCS = [
    "convertToAssets",
    "convertToShares",
    "previewDeposit",
    "previewMint",
    "previewRedeem",
    "previewWithdraw",
]
RATE_CALL_RE = re.compile(r"\b(" + "|".join(RATE_FUNCS) + r")\s*\(")
ERC4626_IMPORT_RE = re.compile(r"import\b.*4626")

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADJUDICATOR = os.path.join(REPO_ROOT, "src", "ArmadaNitroAdjudicator.sol")
NITRO_ROOT = os.path.join(REPO_ROOT, "src", "nitro")


def collect_files() -> list[str]:
    """The set of settlement contracts to scan."""
    files = [ADJUDICATOR]
    if os.path.isdir(NITRO_ROOT):
        for dirpath, _dirs, filenames in os.walk(NITRO_ROOT):
            for fn in filenames:
                if fn.endswith(".sol"):
                    files.append(os.path.join(dirpath, fn))
    return files


def scan_files(paths: list[str]) -> dict[str, list[dict[str, object]]]:
    """Scan .sol files; return findings as lists of (file, line) entries."""
    erc4626_imports = []
    rate_calls = []
    for path in paths:
        with open(path, encoding="utf-8") as f:
            for line_no, line in enumerate(f, 1):
                if ERC4626_IMPORT_RE.search(line):
                    erc4626_imports.append({"file": path, "line": line_no})
                m = RATE_CALL_RE.search(line)
                if m:
                    rate_calls.append({"file": path, "line": line_no, "function": m.group(1) + "("})
    return {"erc4626_imports": erc4626_imports, "rate_calls": rate_calls}


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        fd, tmp_path = tempfile.mkstemp(suffix=".sol")
        with os.fdopen(fd, "w") as f:
            f.write("uint32 convertToAssets(\n")
        result = scan_files([tmp_path])
        detected = len(result["rate_calls"]) >= 1
        json.dump({"self_test_detected": detected}, sys.stdout)
        print()
        return 0 if detected else 1

    files = collect_files()
    findings = scan_files(files)
    output = {
        "files_scanned": len(files),
        "erc4626_imports": findings["erc4626_imports"],
        "rate_calls": findings["rate_calls"],
    }
    json.dump(output, sys.stdout)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
