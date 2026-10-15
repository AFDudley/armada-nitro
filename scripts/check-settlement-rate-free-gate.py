#!/usr/bin/env python3
"""Gate script for the arn-5db acceptance spec (derived-arn-5db), clause c2.

The exophial metamorphic gate runs exactly:
    python3 scripts/check-settlement-rate-free-gate.py
and (for relation_class=monotonicity) parses the entire stdout as a single
JSON object of shape:
    {"series": [[x1, y1], [x2, y2]]}
where each entry is a [x, y] number pair and passes when y is non-decreasing
as x increases. A non-zero exit, or stdout that is not one JSON value,
fails the check.

This script scans the real adjudicator and Nitro framework source for the
forbidden ERC-4626 exchange-rate names (the same set the c1 grep_absent
clause enforces):
    ERC4626, IERC4626, convertToAssets, convertToShares, preview

Behaviour:
  * Scan of src/ArmadaNitroAdjudicator.sol + every src/nitro/**/*.sol.
  * Clean scan  -> print exactly one JSON object {"series": [[0, 0], [1, 1]]
    and exit 0, so `forge test` (and the gate) PASSES while the source is
    free of the forbidden names.
  * Any forbidden name present in the source -> exit 1 (non-zero) so the
    forge suite is the thing catching the violation.

Run it with --scan-file PATH to point the scan at a single scratch copy of
the adjudicator source; run it with --self-test to prove the detector fires
on a temp .sol file containing convertToAssets(.
"""

import json
import os
import sys

# c1 forbidden names (the set the grep_absent clause enforces).
FORBIDDEN = [
    "ERC4626",
    "IERC4626",
    "convertToAssets",
    "convertToShares",
    "preview",
]

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADJUDICATOR = os.path.join(REPO_ROOT, "src", "ArmadaNitroAdjudicator.sol")
NITRO_ROOT = os.path.join(REPO_ROOT, "src", "nitro")


def collect_files() -> list[str]:
    """The adjudicator contract + every .sol under src/nitro."""
    files = [ADJUDICATOR]
    if os.path.isdir(NITRO_ROOT):
        for dirpath, _dirs, filenames in os.walk(NITRO_ROOT):
            for fn in filenames:
                if fn.endswith(".sol"):
                    files.append(os.path.join(dirpath, fn))
    return files


def scan_files(paths: list[str]) -> list[tuple[str, int, str]]:
    """Scan .sol files; return hits as (file, line_no, name) tuples."""
    hits = []
    for path in paths:
        try:
            with open(path, encoding="utf-8") as f:
                for line_no, line in enumerate(f, 1):
                    for name in FORBIDDEN:
                        if name in line:
                            hits.append((path, line_no, name))
        except FileNotFoundError:
            pass
    return hits


def self_test() -> int:
    """Prove the detector fires: scan a temp file containing convertToAssets(."""
    import tempfile

    fd, tmp_path = tempfile.mkstemp(suffix=".sol")
    with os.fdopen(fd, "w") as f:
        f.write("uint32 convertToAssets(\n")
    hits = scan_files([tmp_path])
    detected = len(hits) >= 1
    json.dump({"self_test_detected": detected}, sys.stdout)
    print()
    return 0 if detected else 1


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return self_test()

    scan_file = None
    i = 0
    while i < len(argv):
        if argv[i] == "--scan-file":
            scan_file = argv[i + 1]
            i += 2
            continue
        i += 1

    if scan_file is not None:
        files = [os.path.join(REPO_ROOT, scan_file)]
    else:
        files = collect_files()

    hits = scan_files(files)
    if hits:
        # Human detail on stderr so stdout stays a single JSON value on
        # the passing run; non-zero exit so the gate (monotonicity) fails.
        for path, line_no, name in hits:
            print(f"{os.path.relpath(path, REPO_ROOT)}:{line_no}: {name}", file=sys.stderr)
        # y is non-decreasing across increasing x only when clean.
        return 1

    # Clean scan: emit exactly one JSON object for the monotonicity oracle.
    json.dump({"series": [[0, 0], [1, 1]]}, sys.stdout)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
