#!/usr/bin/env python3
"""E15c discrimination (late response): prove the watchtower's gate rejects a response
submitted after the challenge window, so the response reverts and the payout still equals
state N.

Runs the `armada-watchtower-discrimination-e2e` job on a scratch copy of the fixturenet
(anvil fork, reverted after), with SCENARIO=late_response. The job's JSON line reports
`response_reverted` and `payout_equals_state_n`.
"""

from __future__ import annotations

import json
import sys

import job_runner


def main() -> int:
    json_line = job_runner._run_job("late_response")
    data = json.loads(json_line)
    print(
        json.dumps(
            {
                "response_reverted": data.get("response_reverted"),
                "payout_equals_state_n": data.get("payout_equals_state_n"),
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
