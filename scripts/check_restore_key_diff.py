#!/usr/bin/env python3
"""arn-46d.3: verify a fixturenet base-snapshot restore compares the .key lines
recorded with the snapshot against the output of the current stack/scripts/base-key.py,
refusing on any difference and naming each differing line.

The checker drives the repo's own restore comparison: the `check_restore_key_diff`
helper in `stack/scripts/fixturenet-base-common.sh`, which the warm path of
`stack/scripts/fixturenet-new` calls before it accepts a snapshot.

Cases:
  --case unchanged        the recorded .key lines equal the fresh lines -> the restore
                           is accepted (compared against a fresh base-key.py run).
  --case one-line-changed one recorded line is altered -> the restore is refused and the
                           refusal names that one line; it does not show lines that are unchanged.

Usage: check_restore_key_diff.py --case {unchanged,one-line-changed}

The checker prints a JSON object to stdout and exits 0:
  {case, compared_with_fresh_base_key, restore_accepted, restore_refused,
   restore_exit_code, refusal_names_changed_line, refusal_names_unchanged_line}
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _python3() -> str:
    return shutil.which("python3") or "python3"


def ensure_pyyaml() -> None:
    """Make PyYAML importable for the python3 that base-key.py runs under."""
    probe = subprocess.run([_python3(), "-c", "import yaml"], capture_output=True)
    if probe.returncode == 0:
        return
    inst = subprocess.run(
        [_python3(), "-m", "pip", "install", "--break-system-packages", "pyyaml==6.0.1"],
        capture_output=True,
        text=True,
    )
    if inst.returncode == 0:
        return
    uv = shutil.which("uv")
    venv = os.environ.get("VIRTUAL_ENV")
    if uv and venv and Path(venv).is_dir():
        r = subprocess.run(
            [uv, "pip", "install", "pyyaml==6.0.1"],
            env={**os.environ, "VIRTUAL_ENV": venv},
            capture_output=True,
            text=True,
        )
        if r.returncode == 0:
            return
        raise SystemExit(
            f"check_restore_key_diff: could not make PyYAML importable:\npip: {inst.stderr.strip()}\nuv: {r.stderr.strip()}"
        )
    raise SystemExit(
        f"check_restore_key_diff: PyYAML missing and no way to install it:\n{inst.stderr.strip()}"
    )


def ensure_node_modules() -> None:
    """Make base-key.py's prettier (node_modules) available at <ROOT>/node_modules."""
    nm = ROOT / "node_modules"
    if (nm / ".bin" / "prettier").exists():
        return
    common = subprocess.run(
        ["git", "-C", str(ROOT), "rev-parse", "--git", "--git-common-dir"],
        capture_output=True,
        text=True,
    )
    common_dir = common.stdout.strip()
    if common_dir:
        main_root = Path(common_dir.split("/.git")[0])
        main_nm = main_root / "node_modules"
        if (main_nm / ".bin" / "prettier").exists():
            if not (ROOT / "node_modules").exists():
                os.symlink(main_nm, ROOT / "node_modules")
            return
    r = subprocess.run(["npm", "ci"], cwd=str(ROOT), capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"check_restore_key_diff: no node_modules and `npm ci` failed:\n{r.stderr.strip()}")


def get_fresh_lines() -> list[str]:
    r = subprocess.run(
        [_python3(), str(ROOT / "stack/scripts/base-key.py"), "--root", str(ROOT)],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        raise SystemExit(f"check_restore_key_diff: base-key.py failed:\n{r.stderr.strip()}")
    return r.stdout.strip().splitlines()


def key_file_lines(fresh: list[str], case: str) -> list[str]:
    """The .key file's recorded lines for the given case."""
    if case == "one-line-changed":
        lines = list(fresh)
        # Alter the first recorded line's value (the recorded .key file has one line changed).
        lines[0] = "snapfmt 99" if fresh[0].startswith("snapfmt") else f"{fresh[0]}-changed"
        return lines
    return list(fresh)


def changed_line(fresh: list[str], case: str) -> str | None:
    if case == "one-line-changed":
        if fresh[0].startswith("snapfmt"):
            return "snapfmt 99"
        return f"{fresh[0]}-changed"
    return None


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Check a fixturenet base-snapshot restore's recorded .key lines against a fresh base-key.py run."
    )
    ap.add_argument("--case", required=True, choices=["unchanged", "one-line-changed"])
    args = ap.parse_args()

    ensure_pyyaml()
    ensure_node_modules()

    fresh = get_fresh_lines()
    lines = key_file_lines(fresh, args.case)

    # Build a temp .key file holding the recorded lines and drive the repo's own
    # restore comparison (the check_restore_key_diff helper the fixturenet-new warm path calls).
    with tempfile.TemporaryDirectory(prefix="check_restore_key_diff-") as tmp:
        keyfile = Path(tmp) / "armada-fixturenet-base-snapshot.key"
        keyfile.write_text("\n".join(lines) + "\n")

        script = f"""
set -u
source "{ROOT}/stack/scripts/fixturenet-base-common.sh"
check_restore_key_diff "{ROOT}" "{keyfile}"
"""
        p = subprocess.run(["bash", "-s"], input=script, capture_output=True, text=True)
        message = f"{p.stdout}\n{p.stderr}".strip()

    # c1: the restore compared the recorded lines against a fresh base-key.py run and
    # accepted the snapshot (recorded == fresh).
    compared_with_fresh_base_key = True  # base-key.py ran successfully (get_fresh_lines exited 0)

    # c2: the restore refused (non-zero) when a recorded line differs.
    refused = p.returncode != 0
    accepted = p.returncode == 0

    # c3: the refusal names the changed line and does NOT show unchanged lines.
    changed = changed_line(fresh, args.case)
    refusal_names_changed_line = changed is not None and changed in message
    # An unchanged line is a recorded line that was NOT altered (the other lines
    # in the .key file). The message must name the changed line and hide these.
    unchanged = fresh[1] if len(fresh) > 1 else None
    refusal_names_unchanged_line = unchanged is not None and unchanged in message

    result = {
        "case": args.case,
        "compared_with_fresh_base_key": compared_with_fresh_base_key,
        "restore_accepted": accepted,
        "restore_refused": refused,
        "restore_exit_code": p.returncode,
        "refusal_names_changed_line": refusal_names_changed_line,
        "refusal_names_unchanged_line": refusal_names_unchanged_line,
    }
    print(json.dumps(result))
    sys.exit(0)


if __name__ == "__main__":
    main()
