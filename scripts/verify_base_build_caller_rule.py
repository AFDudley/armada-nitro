#!/usr/bin/env python3
"""Acceptance checker for pebble arn-46d.2.

Simulates the pre-commit check that no gate job, compose job or worker script
calls stack/scripts/fixturenet-base-build.

For each caller kind the checker:
  1. Creates a throwaway git-worktree copy of the repo at the current branch
     HEAD (a clean copy with the new command and the pre-commit hook present,
     and no extra caller).
  2. If a caller is requested (gate / compose /worker), writes a caller file
     into the matching location, commits it (so pre-commit's --all-files sees
     it as a tracked file), and re-runs the hook.
  3. Runs the hook `verify-fixturenet-base-build-callers` via pre-commit.
  4. Reports the hook's exit code and whether the failure message names the
     offending caller file.

Usage:
    python3 scripts/verify_base_build_caller_rule.py --caller-kind {none|gate|compose|worker}

Output: a single JSON object:
    {"hook_exit_code": <int>, "names_caller": <bool>}
The script itself always exits 0 (the hook's exit code is reported, not
returned).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HOOK_ID = "verify-fixturenet-base-build-callers"


def _repo_root() -> Path:
    """The repo root that owns this checkout (the shared integration checkout)."""
    r = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    return Path(r)


def _run(args: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    """Run a command in `cwd` and return the CompletedProcess."""
    return subprocess.run(args, cwd=str(cwd), capture_output=True, text=True)


def _add_caller(cwd: Path, kind: str) -> str:
    """Add a forbidden caller of fixturenet-base-build in the matching location.

    Returns the repo-relative path of the file that holds the call (used to
    verify the hook names the caller).
    """
    if kind == "gate":
        caller = cwd / "env/gates/nitro-e2e/fixturenet-base-build-gate.ts"
        caller.write_text(
            'import { runBaseBuild } from "./base.js";\n'
            'runBaseBuild("stack/scripts/fixturenet-base-build", "myname");\n'
        )
        rel = "env/gates/nitro-e2e/fixturenet-base-build-gate.ts"
    elif kind == "compose":
        caller = cwd / "stack/compose-jobs/docker-compose-armada-base-build.yml"
        caller.write_text(
            "services:\n"
            "  base-build:\n"
            "    image: cerc/armada-nitro-env:local\n"
            "    command: bash /stack/scripts/fixturenet-base-build\n"
        )
        rel = "stack/compose-jobs/docker-compose-armada-base-build.yml"
    elif kind == "worker":
        caller = cwd / "stack/scripts/fixturenet-base-build-worker"
        caller.write_text(
            "#!/usr/bin/env bash\n"
            "# A worker script that calls the base-build command.\n"
            'bash "$PWD/stack/scripts/fixturenet-base-build" myname\n'
        )
        rel = "stack/scripts/fixturenet-base-build-worker"
    else:
        rel = ""
    if rel:
        _run(["git", "add", rel], cwd)
        _run(
            ["git", "commit", "-q", "-m", f"test: {kind} caller of fixturenet-base-build"],
            cwd,
        )
    return rel


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--caller-kind", choices=["none", "gate", "compose", "worker"], default="none")
    args = ap.parse_args()
    kind = args.caller_kind

    repo_root = _repo_root()
    tmp = Path(tempfile.mkdtemp(prefix="arn-46d.2-"))
    # Create a throwaway git worktree copy at the current branch HEAD.
    _run(["git", "worktree", "add", "--quiet", str(tmp), "HEAD"], repo_root)

    caller_rel = _add_caller(tmp, kind)

    # Run the actual pre-commit hook in the throwaway copy.
    result = _run(["pre-commit", "run", HOOK_ID, "--all-files"], tmp)
    hook_exit_code: int = result.returncode
    out: str = (result.stdout or "") + "\n" + (result.stderr or "")
    # The hook's failure message must name the offending caller file.
    if hook_exit_code != 0:
        print(out)  # debug: show why the hook failed
    names_caller = bool(caller_rel) and (caller_rel in out)

    # Clean up the throwaway worktree.
    _run(["git", "worktree", "remove", str(tmp), "--quiet"], repo_root)
    print(json.dumps({"hook_exit_code": hook_exit_code, "names_caller": names_caller}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
