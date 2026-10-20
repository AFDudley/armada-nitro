#!/usr/bin/env python3
"""check_pin.py (arn-4d9): machine-checkable oracle for the lib/armada-poc pin.

This is the acceptance oracle for the pebble. Each subcommand runs the
underlying command and prints one JSON object to stdout; the spec's behavior
tests assert on those JSON fields. The reducer re-runs derived-arn-4d9.spec.json
as the merge gate, so every subcommand must exit 0 and emit the expected field.
"""

import json
import re
import subprocess
import sys

# The M8 privacy pool integrated commit the pin must point at.
EXPECTED_GITLINK = "5d076c4eb9f27dd931d6c0b392b92cd850cb66d5"


def cmd_gitlink(path):
    """gitlink <path>: report the committed gitlink SHA."""
    p = subprocess.run(["git", "ls-tree", "HEAD", path], capture_output=True, text=True)
    link = ""
    if p.returncode == 0 and p.stdout.strip():
        parts = p.stdout.split()
        if len(parts) >= 3:
            link = parts[2]
    print(json.dumps({"gitlink_sha": link}))


def cmd_snark_file(path):
    """snark-file <path>: confirm the Snark library file exists in the pinned checkout."""
    p = subprocess.run(
        ["git", "-C", path, "cat-file", "-e", "HEAD:contracts/privacy-pool/types/SnarkTypes.sol"],
        capture_output=True,
        text=True,
    )
    print(json.dumps({"cat_file_exit": p.returncode}))


def cmd_forge_build():
    """forge-build: run `forge build`, report the exit code."""
    p = subprocess.run(["forge", "build"], capture_output=True, text=True)
    print(json.dumps({"forge_build_exit": p.returncode}))


def cmd_forge_test():
    """forge-test: run `forge test`, report the failed-test count."""
    p = subprocess.run(["forge", "test"], capture_output=True, text=True)
    m = re.search(r"(\d+) failed", p.stdout)
    if m:
        failed = int(m.group(1))
    else:
        failed = 0 if p.returncode == 0 else -1
    print(json.dumps({"failed_count": failed}))


def cmd_pre_commit():
    """pre-commit: run `pre-commit run --all-files`, report whether the forge-test hook passed."""
    p = subprocess.run(["pre-commit", "run", "--all-files"], capture_output=True, text=True)
    forge_test_hook_passed = re.search(r"forge build and test.*Passed", p.stdout) is not None
    print(json.dumps({"forge_test_hook_passed": forge_test_hook_passed}))


def cmd_nitro_untouched(ref):
    """nitro-untouched <ref>: count files under src/nitro that differ from the ref."""
    p = subprocess.run(
        ["git", "diff", "--name-only", ref, "HEAD"],
        capture_output=True,
        text=True,
    )
    changed = [l for l in p.stdout.splitlines() if l.strip().startswith("src/nitro/")]
    print(json.dumps({"changed_files": len(changed)}))


def cmd_no_second_verifier():
    """no-second-verifier: count Groth16 verifier definitions in the repo's own files."""
    verifier_defs = 0
    targets = ["test/", "test/helpers/", "script/"]
    for target in targets:
        for pattern in ["function verifyProof"]:
            out = subprocess.run(["grep", "-rn", pattern, target], capture_output=True, text=True)
            if out.stdout.strip():
                verifier_defs += len(out.stdout.splitlines())
    for target in targets:
        out = subprocess.run(
            ["grep", "-rEn", r"\b(?:contract|library|interface|abstract|struct)\s+\w*[Vv]erifier", target],
            capture_output=True,
            text=True,
        )
        if out.stdout.strip():
            verifier_defs += len(out.stdout.splitlines())
    print(json.dumps({"verifier_definitions": verifier_defs}))


SUBCOMMANDS = {
    "gitlink": cmd_gitlink,
    "snark-file": cmd_snark_file,
    "forge-build": cmd_forge_build,
    "forge-test": cmd_forge_test,
    "pre-commit": cmd_pre_commit,
    "nitro-untouched": cmd_nitro_untouched,
    "no-second-verifier": cmd_no_second_verifier,
}


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: check_pin.py <subcommand> [args]"}))
        return 1
    sub = sys.argv[1]
    if sub not in SUBCOMMANDS:
        print(json.dumps({"error": "unknown subcommand: " + sub}))
        return 1
    handler = SUBCOMMANDS[sub]
    args = sys.argv[2:]
    if sub in ("gitlink", "snark-file", "nitro-untouched"):
        if len(args) < 1:
            print(json.dumps({"error": sub + " requires an argument"}))
            return 1
        handler(args[0])
    elif sub in ("forge-build", "forge-test", "pre-commit", "no-second-verifier"):
        handler()
    return 0


if __name__ == "__main__":
    sys.exit(main())
