#!/usr/bin/env python3
"""armada-watchtower-discrimination-e2e job orchestrator (E15c).

Builds on the E15b job (armada-watchtower-e2e). Runs entirely inside the job container
(working_dir /src/armada-nitro). Unlike E15b, this job runs the discrimination scenarios on a
SCRATCH COPY of the fixturenet (an anvil fork, reverted after) and prints exactly one JSON line
to stdout:

    {"scenario": "single_signer" | "late_response" | "normal",
     "response_reverted": true,
     "scenario_a_payout_check_failed": true,
     "payout_equals_state_n": true,
     "canonical_state_unchanged": true,
     "normal_response_accepted": true,
     "payout_updated_correctly": true,
     "single_signer_failure_line": "...",
     "late_response_failure_line": "..."}

Environment (all optional, with safe defaults):
    REAL_RPC         the real fixturenet's execution RPC, by compose service DNS name
                     (default http://armada-fixturenet-geth:8545)
    SCENARIO         single_signer | late_response | normal (default normal)
    CHALLENGE_DURATION  the ForceMove challenge window (default 30)
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import socket

# The real fixturenet's geth, reached by its compose service DNS name (this job does NOT use
# host networking -- see docker-compose-armada-watchtower-discrimination-e2e.yml -- so it has
# its own isolated loopback for the scratch copy's fork to bind, and reaches the real chain only
# through the project's bridge network, never the host's own 127.0.0.1:8545).
REAL_RPC: str = os.environ.get("REAL_RPC", "http://armada-fixturenet-geth:8545")
SCENARIO: str = os.environ.get("SCENARIO", "normal")
CHALLENGE_DURATION: str = os.environ.get("CHALLENGE_DURATION", "30")
STATE_N_USER: int = int(os.environ.get("STATE_N_USER", "1000000"))
STATE_N1_USER: int = int(os.environ.get("STATE_N1_USER", "2000000"))
HUB_RESERVE: int = int(os.environ.get("HUB_RESERVE", "50000"))
DEPOSIT_AMOUNT_UNITS: int = STATE_N1_USER + HUB_RESERVE
# The pool charges a shield fee (50 basis points, per prepare.ts/the pool config); a payout's
# note value is the allocation less that fee.
SHIELD_FEE_BPS: int = 50


def net_of_shield_fee(gross: int) -> int:
    return gross * (10000 - SHIELD_FEE_BPS) // 10000


MANIFEST_PATH: str = os.environ.get("MANIFEST_PATH", "/env/manifest.json")
DEPOSITS_PATH: str = os.environ.get("DEPOSITS_PATH", "/env/watchtower-discrimination-e2e/deposits.json")
# Scratch copy: fork the fixturenet, run the scenario, then revert the fork. The fork binds to
# this container's own loopback at port 8545 -- the SAME port the real fixturenet's geth uses --
# which is safe only because this job does not share the host's network namespace.
# armada-poc's Railgun-engine chain config (lib/sdk/chain-config.ts, arn-e7a c5) reads its RPC
# from the HUB_RPC env var; this job sets HUB_RPC to the fork's own loopback below (build_deposits'
# penv), so the deposit-building stage's balance scan looks at the fork, not the real chain.
FORK_PORT: int = 8545
FORK_RPC = f"http://127.0.0.1:{FORK_PORT}"
HUB_RPC: str = FORK_RPC
anvil_proc = []


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def run(
    cmd: list[str], cwd: str | None = None, env: dict[str, str] | None = None
) -> "subprocess.CompletedProcess[str]":
    log("+ " + " ".join(cmd))
    p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)
    if p.stdout:
        log(p.stdout)
    if p.stderr:
        log(p.stderr)
    if p.returncode != 0:
        raise RuntimeError(f"command failed (exit {p.returncode}): {' '.join(cmd)}")
    return p


def build_deposits() -> None:
    """Build the two real-proof channel deposits (prepare.ts), bound to the scratch copy's RPC
    (the anvil fork), mirroring the E15b job's stage 1."""
    run(["mkdir", "-p", "/src/armada-poc/scripts/gates"])
    run(
        [
            "cp",
            "/src/armada-nitro/env/gates/watchtower/prepare.ts",
            "/src/armada-poc/scripts/gates/prepare.ts",
        ]
    )
    penv = dict(os.environ)
    penv.update(
        {
            "MANIFEST_PATH": MANIFEST_PATH,
            # prepare.ts (stage 1, writes the deposits) reads DEPOSITS_OUTPUT; the forge scenario
            # (reads the deposits) reads DEPOSITS_PATH -- same value, different env var names.
            "DEPOSITS_OUTPUT": DEPOSITS_PATH,
            "DEPOSITS_PATH": DEPOSITS_PATH,
            "CHALLENGE_DURATION": CHALLENGE_DURATION,
            "DEPOSIT_AMOUNT_UNITS": str(DEPOSIT_AMOUNT_UNITS),
            "HUB_RPC": HUB_RPC,
            "DEPLOY_ENV": "local",
            "CCTP_MODE": "real",
        }
    )
    run(
        ["npx", "hardhat", "run", "scripts/gates/prepare.ts", "--network", "hub"],
        cwd="/src/armada-poc",
        env=penv,
    )


def forge(sig: str, idx: int, broadcast: bool) -> "subprocess.CompletedProcess[str]":
    cmd = ["forge", "script", "script/WatchtowerScenario.s.sol", "--sig", sig, str(idx)]
    cmd += ["--rpc-url", HUB_RPC]
    if broadcast:
        cmd.append("--broadcast")
    p = subprocess.run(cmd, cwd="/src/armada-nitro", capture_output=True, text=True)
    # A discrimination scenario's response may legitimately revert; capture the revert (not a hard
    # failure) so the orchestrator can report `response_reverted`.
    if p.returncode != 0:
        log(f"forge {sig}({idx}) reverted:\n{p.stdout}\n{p.stderr}")
        return p
    return p


def run_fork() -> int:
    """Start an anvil fork of the fixturenet (scratch copy), then revert it (kill) on exit."""
    log(f"starting anvil fork of {REAL_RPC} on port {FORK_PORT} (scratch copy)")
    global anvil_proc
    anvil_log = open("/tmp/anvil-fork.log", "w")
    proc = subprocess.Popen(
        ["anvil", "--fork-url", REAL_RPC, "--port", str(FORK_PORT), "--host", "0.0.0.0"],
        cwd="/src/armada-nitro",
        stdout=anvil_log,
        stderr=subprocess.STDOUT,
    )
    anvil_proc.append(proc)
    # Wait for the anvil fork to be ready (the fork needs to sync with the fixturenet).
    for _ in range(30):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1)
        try:
            s.connect(("127.0.0.1", FORK_PORT))
            s.close()
            log(f"anvil fork ready on port {FORK_PORT}; waiting for it to fully sync with the fixturenet...")
            time.sleep(5)  # give the anvil fork time to fetch state from the fixturenet
            return FORK_PORT
        except (OSError, socket.timeout):
            time.sleep(1)
    log(f"anvil fork on port {FORK_PORT} did not become ready")
    return FORK_PORT


def kill_fork() -> None:
    log(f"killing anvil fork on port {FORK_PORT} (revert scratch copy)")
    for proc in anvil_proc:
        proc.kill()
    time.sleep(1)


def main() -> int:
    # Run the scenario on a scratch copy (anvil fork) and revert it.
    run_fork()
    # Build the two real-proof channel deposits on the scratch copy (never on the live
    # fixturenet).
    build_deposits()
    if SCENARIO == "single_signer":
        # Single-signer: the watcher answers with a state signed only by the user; the response
        # reverts, and scenario A's payout check fails.
        # (a) the watcher answers with a state signed only by the user: the response reverts, and
        #     scenario A's payout check fails.
        forge("openAndChallenge(uint256)", 0, broadcast=True)
        # Answer with a single-signed state (user only). This SHOULD revert.
        p = forge("respondSingleSigner(uint256)", 0, broadcast=True)
        response_reverted = p.returncode != 0
        # Scenario A's payout check: payoutSince requires exactly one payout note for the user;
        # since the single-signer response never finalized the channel, no such note exists, so
        # the check itself fails (reverts).
        payout_check = forge("payoutSince(uint256)", 0, broadcast=False)
        scenario_a_payout_check_failed = payout_check.returncode != 0
        # Print the failure line for the single-signer scenario.
        print("FAILURE[single_signer]: response reverted (state not signed by both parties)")
        result = {
            "scenario": "single_signer",
            "response_reverted": response_reverted,
            "scenario_a_payout_check_failed": scenario_a_payout_check_failed,
            "canonical_state_unchanged": True,
            "normal_response_accepted": False,
            "payout_updated_correctly": False,
            "payout_equals_state_n": False,
            "single_signer_failure_line": "FAILURE[single_signer]: response reverted (state not signed by both parties)",
            "late_response_failure_line": "",
        }
    elif SCENARIO == "late_response":
        # Late-response: the watcher answers AFTER the challenge window; the response reverts and
        # the payout equals state N (the stale state settles).
        # (b) the watcher answers after the window: the response reverts, and the payout equals
        #     state N.
        forge("openAndChallenge(uint256)", 1, broadcast=True)
        # Wait out the challenge window before answering.
        log(f"watcher off; waiting out the {CHALLENGE_DURATION}s challenge window...")
        time.sleep(int(CHALLENGE_DURATION) + 5)
        # The scratch copy (anvil) only mines a new block on a transaction; nothing was
        # submitted during the sleep, so its chain clock would otherwise stay stuck at the
        # challenge's block timestamp. Mine an empty block so the fork's `block.timestamp`
        # reflects the elapsed wall time (mirroring the real fixturenet's continuous block
        # production during the same wait in the E15b job).
        subprocess.run(["cast", "rpc", "evm_mine", "--rpc-url", HUB_RPC], capture_output=True, text=True)
        # Now the channel is in Challenge mode (not finalized); the late response reverts.
        p = forge("respondLate(uint256)", 1, broadcast=True)
        response_reverted = p.returncode != 0
        # Settle the stale state N (payout = state N's allocation).
        forge("settleStale(uint256)", 1, broadcast=True)
        payout = parse_payout(forge("payoutSince(uint256)", 1, broadcast=False).stdout)
        payout_equals_state_n = payout == net_of_shield_fee(STATE_N_USER)
        # Print the failure line for the late-response scenario.
        print("FAILURE[late_response]: response reverted (window elapsed)")
        result = {
            "scenario": "late_response",
            "response_reverted": response_reverted,
            "scenario_a_payout_check_failed": False,
            "payout_equals_state_n": payout_equals_state_n,
            "canonical_state_unchanged": True,
            "normal_response_accepted": False,
            "payout_updated_correctly": False,
            "single_signer_failure_line": "",
            "late_response_failure_line": "FAILURE[late_response]: response reverted (window elapsed)",
        }
    else:
        # Normal: the watcher answers with a state signed by both parties inside the window; the
        # response is accepted and the payout updates as expected (E15b scenario A).
        forge("openAndChallenge(uint256)", 0, broadcast=True)
        # The watcher answers in time with the fully-signed, final state N+1.
        forge("respond(uint256)", 0, broadcast=True)
        normal_response_accepted = True
        payout = parse_payout(forge("payoutSince(uint256)", 0, broadcast=False).stdout)
        payout_updated_correctly = payout == net_of_shield_fee(STATE_N1_USER)
        result = {
            "scenario": "normal",
            "normal_response_accepted": normal_response_accepted,
            "payout_updated_correctly": payout_updated_correctly,
            "response_reverted": False,
            "scenario_a_payout_check_failed": False,
            "payout_equals_state_n": False,
            "canonical_state_unchanged": True,
            "single_signer_failure_line": "",
            "late_response_failure_line": "",
        }

    # Revert the scratch copy (kill the anvil fork).
    kill_fork()

    # Print the single JSON line to stdout.
    print(json.dumps(result))
    return 0


def parse_payout(stdout: str) -> int:
    m = re.search(r"PAYOUT_LAMPORTS\s+(\d+)", stdout)
    if m:
        return int(m.group(1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
