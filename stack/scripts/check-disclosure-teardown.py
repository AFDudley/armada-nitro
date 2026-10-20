#!/usr/bin/env python3
"""arn-2fd c5: no fixturenet created by an armada-disclosure-acceptance run is left running or
stored.

stack/scripts/armada-disclosure-acceptance.py names its fixturenet
`armada-disclosure-acceptance-<epoch>-<pid>` and, on exit (including on failure: the teardown is
in a `finally` block), stops it, deletes its volumes, unmounts its RAM disk and removes its
deployment directory and spec file under ~/deployments. This counts any of that run's
deployment directories or spec files still present, as one run name's worth of leftover state
each.

Prints one JSON line: {"leftover_fixturenets": <int>}. Zero when no such name remains.
"""

from __future__ import annotations

import glob
import json
import os
import sys

PATTERN = os.path.expanduser("~/deployments/armada-disclosure-acceptance-*")


def main() -> int:
    names: set[str] = set()
    for path in glob.glob(PATTERN):
        base = os.path.basename(path)
        if base.endswith("-spec.yml"):
            base = base[: -len("-spec.yml")]
        names.add(base)
    print(json.dumps({"leftover_fixturenets": len(names)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
