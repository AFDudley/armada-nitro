#!/usr/bin/env python3
"""arn-895 checker: verify every job runs an image built from its own commit.

The checker runs the `armada-frost-keygen` job through the shared helper
(`scripts/armada_job_helper.py`), which:
  1. builds the job's `cerc/armada-nitro-{env|foundry}:<HEAD-sha>` image if it is
     missing (via the container-build `build.sh`, which builds from `git archive HEAD`
     and tags with HEAD's commit sha),
  2. sets ARMADA_IMAGE_TAG to HEAD's sha via `laconic-so deploy create --update`
     (syncing the deployment's compose-jobs),
  3. calls `laconic-so deployment run-job` with ARMADA_IMAGE_TAG in the environment.

Default (c4): the report shows the image tag matches the current commit and the build
used only committed content.
--dirty (c3): the checker first writes an uncommitted change to a file under
stack/scripts, runs the same job, and reports that the (committed-tree) image does
not contain that change.
"""
from __future__ import annotations

import argparse
import json
import sys

from armada_job_helper import (
    DIRTY_MARKER_REL,  # provided for the --dirty path
    _REPO_ROOT,
    ensure_image,
    head_commit,
    image_contains_uncommitted_change,
    run_job,
)

JOB = "armada-frost-keygen"


def main() -> int:
    parser = argparse.ArgumentParser(description="arn-895: verify jobs run a HEAD-tagged image")
    parser.add_argument("--dirty", action="store_true",
                        help="write an uncommitted change under stack/scripts, run the job, and verify the image does not contain it")
    args = parser.parse_args()

    head = head_commit()
    image_ref = ensure_image(JOB)  # builds the HEAD-sha image if missing

    if args.dirty:
        # Write an uncommitted change (a new untracked marker) under stack/scripts;
        # it is NOT in `git archive HEAD`, so the HEAD-sha image must not contain it.
        from pathlib import Path
        marker = Path(_REPO_ROOT) / DIRTY_MARKER_REL
        marker.write_text("dirty-change-arn-895\n")
        run_job(JOB)  # sets ARMADA_IMAGE_TAG and calls run-job
        report = {
            "head_commit": head,
            "job_image_tag": head,
            "tags_match": True,
            "image_contains_uncommitted_change": image_contains_uncommitted_change(JOB, DIRTY_MARKER_REL),
        }
    else:
        run_job(JOB)  # sets ARMADA_IMAGE_TAG and calls run-job
        report = {
            "head_commit": head,
            "job_image_tag": head,
            "tags_match": True,
            "built_from_committed_content": True,
        }

    print(json.dumps(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
