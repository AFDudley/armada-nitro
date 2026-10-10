#!/usr/bin/env python3
"""E15c scratch isolation: prove both discrimination scenarios ran on a scratch copy
(anvil fork) that was reverted after, leaving the original fixturenet state unchanged.

Checks a canonical value on the REAL fixturenet (not the job's scratch copy) before and
after running the discrimination job: the user test account's transaction count (nonce) at
http://127.0.0.1:8545. The job forks the fixturenet and runs every scenario (including
on-chain transactions) only against that fork, then reverts it (kills the anvil fork); if
the job ever touched the real chain, the user account's nonce there would move. This is a
direct RPC read of the live deployment (permitted per the operator's constraints), not a
file read of the deployment's data directory.
"""
from __future__ import annotations

import json
import sys
import urllib.request

import job_runner

REAL_RPC = "http://127.0.0.1:8545"
# The fixturenet's first test account (the "user" in WatchtowerScenario.s.sol), a
# deterministic anvil/hardhat dev account.
USER_ADDRESS = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"


def real_chain_nonce() -> int:
    payload = json.dumps(
        {
            "jsonrpc": "2.0",
            "method": "eth_getTransactionCount",
            "params": [USER_ADDRESS, "latest"],
            "id": 1,
        }
    ).encode()
    req = urllib.request.Request(
        REAL_RPC, data=payload, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = json.loads(resp.read())
    return int(body["result"], 16)


def main() -> int:
    nonce_before = real_chain_nonce()
    # Run both discrimination scenarios on scratch copies (each job invocation forks the
    # fixturenet, runs on the fork, and reverts it).
    job_runner._run_job("single_signer")
    job_runner._run_job("late_response")
    nonce_after = real_chain_nonce()
    print(json.dumps({
        "canonical_state_unchanged": nonce_after == nonce_before,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
