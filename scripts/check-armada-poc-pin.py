#!/usr/bin/env python3
"""check-armada-poc-pin.py (arn-e7a c5): the armada-poc submodule's gitlink must point
at a commit other than the old pin 532bc064 (a new commit pushed to the AFDudley fork).

Prints one JSON object: {"pin_is_old": bool, "gitlink": str, "old_pin": str}.
The acceptance oracle asserts pin_is_old == False.
"""

import json
import subprocess
import sys

OLD_PIN = "532bc0641443879e30c07b98970f6e11d500c"


def current_gitlink() -> str:
    """The submodule's gitlink as committed in HEAD (not the working tree)."""
    out = subprocess.run(
        ["git", "ls-tree", "HEAD", "lib/armada-poc"],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0 or not out.stdout.strip():
        return ""
    parts = out.stdout.split()
    if len(parts) >= 2:
        return parts[1]
    return ""


def main() -> int:
    link = current_gitlink()
    pin_is_old = link == OLD_PIN
    print(json.dumps({"pin_is_old": pin_is_old, "gitlink": link, "old_pin": OLD_PIN}))
    return 0 if pin_is_old is False else 1


if __name__ == "__main__":
    sys.exit(main())
