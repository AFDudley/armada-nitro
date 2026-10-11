#!/usr/bin/env python3
"""E15c normal response: prove the watchtower's normal behavior is unchanged -- when it
answers with a state signed by both parties inside the challenge window, the response is
accepted and the payout updates as expected.

Runs the `armada-watchtower-discrimination-e2e` job with SCENARIO=normal. The job's JSON
line reports `normal_response_accepted` and `payout_updated_correctly`.
"""

from __future__ import annotations

import json
import sys

import job_runner


def main() -> int:
    json_line = job_runner._run_job("normal")
    data = json.loads(json_line)
    print(
        json.dumps(
            {
                "normal_response_accepted": data.get("normal_response_accepted"),
                "payout_updated_correctly": data.get(json_line and "payout_updated_correctly"),
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
