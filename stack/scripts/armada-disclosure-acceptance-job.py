#!/usr/bin/env python3
"""armada-disclosure-acceptance job orchestrator (arn-2fd).

Runs entirely inside the job container (working_dir /src/armada-nitro). Runs the
selective-disclosure chain of custody (docs/tasks/16-selective-disclosure.md, hops H1, H2, H4,
H5, H6, H7) as real transactions against this fixturenet, in three stages:

    stage 1 (env/gates/disclosure/prepare.ts, armada-poc's hardhat/lib/sdk toolchain):
        H1 shield 150 USDC from a test EOA into a fresh wallet; H2+H4 build a real-proof
        depositFromNote bound to a fresh channel; precompute a second note of the same wallet
        (npk2, real ciphertext) for the channel's payout.
    stage 2 (script/DisclosureScenario.s.sol, forge): H4 fund the channel; H7 co-sign the
        post-deposit and final channel states; H5 conclude, shielding npk2.
    stage 3 (env/gates/disclosure/finish.ts): confirm H5's Shield event really pays npk2; H6
        unshield that note to a second test EOA.

Writes /env/disclosure/package.json (the disclosure package: every hop's transaction hashes and
events) and prints exactly one JSON line to stdout: {"hops_ok", "eoa2_usdc_delta",
"eoa_distinct", "payout_note_owned"} -- stack/scripts/armada-disclosure-acceptance.py (run on the
host) adds "package_path" once it copies the package file out of the deployment's /env volume.

Environment (all optional, with safe defaults):
    HUB_RPC             execution RPC (default http://armada-fixturenet-geth:8545)
    MANIFEST_PATH       deployment manifest (default /env/manifest.json)
    DISCLOSURE_DIR      stage artifacts + final package (default /env/disclosure)
    CHALLENGE_DURATION  the ForceMove challenge window (default 30)
    DELEGATE_KEY        the hub's delegate EOA key (same default as the nitro-e2e gate)
    FROST_SHARES_DIR, FROST_SIGNER  the custodian's FROST signer (default /env, frost-signer)
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

HUB_RPC: str = os.environ.get("HUB_RPC", "http://armada-fixturenet-geth:8545")
MANIFEST_PATH: str = os.environ.get("MANIFEST_PATH", "/env/manifest.json")
DISCLOSURE_DIR: str = os.environ.get("DISCLOSURE_DIR", "/env/disclosure")
CHALLENGE_DURATION: str = os.environ.get("CHALLENGE_DURATION", "30")
CHAIN_ID: str = "31337"
BCAST: str = f"/src/armada-nitro/broadcast/DisclosureScenario.s.sol/{CHAIN_ID}"


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


def forge_script(sig: str, broadcast: bool) -> "subprocess.CompletedProcess[str]":
    cmd = [
        "forge",
        "script",
        "script/DisclosureScenario.s.sol",
        "--sig",
        sig,
        "--rpc-url",
        HUB_RPC,
        "--slow",
        "--ffi",
    ]
    if broadcast:
        cmd.append("--broadcast")
    env = dict(os.environ)
    env["DISCLOSURE_DIR"] = DISCLOSURE_DIR
    env["MANIFEST_PATH"] = MANIFEST_PATH
    env["CHALLENGE_DURATION"] = CHALLENGE_DURATION
    p = subprocess.run(cmd, cwd="/src/armada-nitro", env=env, capture_output=True, text=True)
    if p.stdout:
        log(p.stdout)
    if p.stderr:
        log(p.stderr)
    if p.returncode != 0:
        raise RuntimeError(f"forge --sig {sig} failed (exit {p.returncode})")
    return p


def bcast_tx(fn_file: str, fn_prefix: str) -> str:
    path = f"{BCAST}/{fn_file}-latest.json"
    data = json.load(open(path))
    for tx in data.get("transactions", []):
        if (tx.get("function") or "").startswith(fn_prefix):
            return str(tx["hash"])
    raise RuntimeError(f"no {fn_prefix} tx in {path}")


# ---- stage 1: env/gates/disclosure/prepare.ts, armada-poc's toolchain ----
# (funding top-up + circuits verification happen in the compose job's shell wrapper, before this
# script runs -- same split as armada-watchtower-e2e-job.py / docker-compose-armada-watchtower-e2e.yml.)
run(["mkdir", "-p", "/src/armada-poc/scripts/gates"])
run(
    [
        "cp",
        "/src/armada-nitro/env/gates/disclosure/prepare.ts",
        "/src/armada-poc/scripts/gates/disclosure-prepare.ts",
    ]
)
penv = dict(os.environ)
penv.update(
    {
        "MANIFEST_PATH": MANIFEST_PATH,
        "DISCLOSURE_DIR": DISCLOSURE_DIR,
        "CHALLENGE_DURATION": CHALLENGE_DURATION,
        "HUB_RPC": HUB_RPC,
        "DEPLOY_ENV": "local",
        "CCTP_MODE": "real",
    }
)
run(
    ["npx", "hardhat", "run", "scripts/gates/disclosure-prepare.ts", "--network", "hub"],
    cwd="/src/armada-poc",
    env=penv,
)

# ---- stage 2: script/DisclosureScenario.s.sol ----
forge_script("setUpHub()", broadcast=True)
forge_script("fundAndClose()", broadcast=True)
conclude_tx = bcast_tx("fundAndClose", "conclude(")
log(f"conclude tx: {conclude_tx}")

# ---- stage 3: env/gates/disclosure/finish.ts ----
run(
    [
        "cp",
        "/src/armada-nitro/env/gates/disclosure/finish.ts",
        "/src/armada-poc/scripts/gates/disclosure-finish.ts",
    ]
)
fenv = dict(os.environ)
fenv.update(
    {
        "MANIFEST_PATH": MANIFEST_PATH,
        "DISCLOSURE_DIR": DISCLOSURE_DIR,
        "HUB_RPC": HUB_RPC,
        "DEPLOY_ENV": "local",
        "CCTP_MODE": "real",
        "CONCLUDE_TX_HASH": conclude_tx,
    }
)
run(
    ["npx", "hardhat", "run", "scripts/gates/disclosure-finish.ts", "--network", "hub"],
    cwd="/src/armada-poc",
    env=fenv,
)

package = json.load(open(f"{DISCLOSURE_DIR}/package.json"))
# The full package travels through this one stdout line -- the host-side
# stack/scripts/armada-disclosure-acceptance.py never reads the deployment's own /env volume
# from the host (gate-no-host-deployment-access): it writes `package` to its own host file and
# reports that path.
print(
    json.dumps(
        {
            "hops_ok": package["hops_ok"],
            "eoa2_usdc_delta": package["eoa2_usdc_delta"],
            "eoa_distinct": package["eoa_distinct"],
            "payout_note_owned": package["payout_note_owned"],
            "package": package,
        }
    )
)
