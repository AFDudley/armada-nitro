#!/usr/bin/env python3
"""E15c discrimination (single-signer): prove the watchtower's gate rejects a state signed
only by the user, so the response reverts and scenario A's payout check fails.

Runs the `armada-watchtower-discrimination-e2e` job on a scratch copy of the fixturenet
(anvil fork, reverted after), with SCENARIO=single_signer. The job's JSON line reports
`response_reverted` and `scenario_a_payout_check_failed`.
"""

from __future__ import annotations

import json
import sys

import job_runner


def main() -> int:
    json_line = job_runner._run_job("single_signer")
    data = json.loads(json_line)
    print(
        json.dumps(
            {
                "response_reverted": data.get("response_reverted"),
                "scenario_a_payout_check_failed": data.get("scenario_a_payout_check_failed"),
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
