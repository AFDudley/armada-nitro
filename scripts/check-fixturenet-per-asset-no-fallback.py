#!/usr/bin/env python3
"""arn-58d checker: `script/FixturenetScenario.s.sol` pays the cooperative close (channel 0) and
the forced settle (channel 1) through the adjudicator's own per-asset `transfer(assetIndex, ...)`
calls, with no payout depending on, or trying and falling back from, the all-assets payout
functions `transferAllAssets` / `concludeAndTransferAllAssets`.

Drives the real `FixturenetScenario.s.sol` against a fresh local anvil node, against a two-asset
forced channel whose second asset (`RevertingTransferToken`) always reverts on `transfer`
(`script/CheckSettlePerAssetSetup.s.sol`'s own one-shot setup).

Evidence for "which function actually got broadcast" is read from `forge script`'s own
`broadcast/FixturenetScenario.s.sol/<chainid>/<sig>-latest.json` -- each entry's `function` field
is the exact Solidity signature forge resolved and sent, not a string match against console
output (which forge omits for successful broadcasts at default verbosity).

Prints one JSON line with fields (the reducer's spec oracle reads exactly these):
  - cooperative_close_is_per_asset_transfer
  - settle_broadcast_is_per_asset_only
  - settle_first_asset_paid
  - settle_second_asset_holdings_unchanged
  - cooperative_close_used_conclude_all
  - settle_mentions_transfer_all_in_trace

Exits non-zero if any field is not its spec-required value.
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import time

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]

# anvil's well-known default dev-account private keys (accounts 0 and 1) -- local chain
# only, the same ones `scripts/check-e2e-settle-per-asset.py` already uses as its defaults.
DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
USER_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
DELEGATE_KEY = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
CHALLENGE_DURATION = 5
HUB_REVOCATION_DELAY = 60
# Scenario constants (must match FixturenetScenario.s.sol's payout amounts):
FORCED_HUB = 50_000_000

WORKDIR = REPO_ROOT / "deployments" / "check-fixturenet-per-asset"
# The FROST 2-of-3 group (shares + group key) for the custodian the scenario signs for.
FROST_SHARES_DIR = WORKDIR / "frost"
# The host-side frost-signer binary (built by cargo):
FROST_SIGNER = REPO_ROOT / "target" / "release" / "frost-signer"
CHAIN_ID = 31337


def _keygen_frost_group() -> None:
    """Build the host frost-signer and keygen a 2-of-3 FROST group into FROST_SHARES_DIR. The
    setup script deploys the custodian with this group's key, and FixturenetScenario.s.sol signs
    the custodian's `execute` calls with two of its shares."""
    if not FROST_SIGNER.exists():
        _run(["cargo", "build", "--release", "-p", "frost-signer"], os.environ.copy(), REPO_ROOT)
    if (FROST_SHARES_DIR / "group-pubkey.json").exists():
        # already keygen'd; the shares + group key persist in WORKDIR/frost
        return
    # Ensure the directory exists, then keygen the group.
    FROST_SHARES_DIR.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [str(FROST_SIGNER), "keygen", "--out", str(FROST_SHARES_DIR)], capture_output=True, text=True
    )
    if result.returncode != 0:
        sys.stderr.write(f"frost-signer keygen failed (exit {result.returncode})")
        sys.stderr.write(result.stdout[-4000:])
        sys.stderr.write(result.stderr[-4000:])
        raise SystemExit(result.returncode)


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def _run(cmd: list[str], env: dict[str, str], cwd: pathlib.Path) -> str:
    result = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=300)
    if result.returncode != 0:
        sys.stderr.write(f"command failed: {' '.join(cmd)}\n")
        sys.stderr.write(result.stdout[-4000:])
        sys.stderr.write(result.stderr[-4000:])
        raise SystemExit(result.returncode)
    return result.stdout


def _forge_script(sig: str, rpc: str, env: dict[str, str]) -> list[str]:
    """Runs `forge script FixturenetScenario.s.sol --sig <sig> --broadcast`, and returns the
    list of fully-qualified function signatures forge actually broadcast as transactions (read
    from its own per-run broadcast artifact, not from console output)."""
    cmd = [
        "forge",
        "script",
        "script/FixturenetScenario.s.sol",
        "--sig",
        sig,
        "--rpc-url",
        rpc,
        "--slow",
        "--broadcast",
        "--ffi",
    ]
    _run(cmd, env, REPO_ROOT)
    bare_sig = sig.split("(")[0]
    broadcast_path = (
        REPO_ROOT / "broadcast" / "FixturenetScenario.s.sol" / str(CHAIN_ID) / f"{bare_sig}-latest.json"
    )
    if not broadcast_path.exists():
        # e.g. earlySettle(): deliberately broadcasts nothing (its only call is a raw,
        # never-broadcast `.call()` that must revert -- see FixturenetScenario.s.sol).
        return []
    broadcast = json.loads(broadcast_path.read_text())
    return [tx["function"] for tx in broadcast["transactions"]]


def _cast_call(adjudicator: str, asset: str, channel_id: str, rpc: str) -> int:
    out = _run(
        [
            "cast",
            "call",
            adjudicator,
            "holdings(address,bytes32)(uint256)",
            asset,
            channel_id,
            "--rpc-url",
            rpc,
        ],
        os.environ.copy(),
        REPO_ROOT,
    )
    return int(out.strip().split()[0])


def _cast_balance(token: str, holder: str, rpc: str) -> int:
    out = _run(
        ["cast", "call", token, "balanceOf(address)(uint256)", holder, "--rpc-url", rpc],
        os.environ.copy(),
        REPO_ROOT,
    )
    return int(out.strip().split()[0])


def main() -> int:
    if shutil.which("forge") is None or shutil.which("anvil") is None or shutil.which("cast") is None:
        sys.stderr.write("forge/anvil/cast not found on PATH\n")
        return 1

    if WORKDIR.exists():
        shutil.rmtree(WORKDIR)
    (WORKDIR / "nitro-e2e").mkdir(parents=True)
    _keygen_frost_group()

    port = _free_port()
    rpc = f"http://127.0.0.1:{port}"
    anvil = subprocess.Popen(
        ["anvil", "--port", str(port), "--silent"],
        cwd=REPO_ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    try:
        deadline = time.time() + 30
        ready = False
        while time.time() < deadline:
            probe = subprocess.run(
                ["cast", "block-number", "--rpc-url", rpc], cwd=REPO_ROOT, capture_output=True, text=True
            )
            if probe.returncode == 0:
                ready = True
                break
            time.sleep(0.5)
        if not ready:
            sys.stderr.write("anvil did not become ready\n")
            return 1

        manifest_path = WORKDIR / "manifest.json"
        deposits_path = WORKDIR / "nitro-e2e" / "deposits.json"
        env = os.environ.copy()
        env.update(
            {
                "DEPLOYER_KEY": DEPLOYER_KEY,
                "USER_KEY": USER_KEY,
                "DELEGATE_KEY": DELEGATE_KEY,
                "FROST_SHARES_DIR": str(FROST_SHARES_DIR.relative_to(REPO_ROOT)),
                "FROST_SIGNER": str(FROST_SIGNER),
                "CHALLENGE_DURATION": str(CHALLENGE_DURATION),
                "HUB_REVOCATION_DELAY": str(HUB_REVOCATION_DELAY),
                "MANIFEST_PATH": str(manifest_path.relative_to(REPO_ROOT)),
                "DEPOSITS_PATH": str(deposits_path.relative_to(REPO_ROOT)),
                "KEYS_DIR": str(WORKDIR.relative_to(REPO_ROOT)),
            }
        )

        # Deploy a fresh fixturenet-shaped environment with a second (always-reverts-on-transfer)
        # channel asset, then write manifest.json / deposits.json / keys in the shapes the
        # scenario reads.
        _run(
            [
                "forge",
                "script",
                "script/CheckSettlePerAssetSetup.s.sol",
                "--rpc-url",
                rpc,
                "--slow",
                "--broadcast",
            ],
            env,
            REPO_ROOT,
        )

        manifest = json.loads(manifest_path.read_text())
        deposits = json.loads(deposits_path.read_text())
        adjudicator = manifest["armadaNitro"]["adjudicator"]
        custodian = manifest["armadaNitro"]["hubCustodian"]
        usdc = manifest["armada"]["usdc"]
        usdc2 = manifest["armada"]["usdc2"]
        channel0_id = deposits["deposits"][0]["channelId"]
        channel1_id = deposits["deposits"][1]["channelId"]

        # -- setUpHub
        _forge_script("setUpHub()", rpc, env)

        # -- cooperative close (channel 0, single-asset)
        coop_fns = _forge_script("cooperativeClose()", rpc, env)
        cooperative_close_used_conclude_all = any(
            fn.startswith("concludeAndTransferAllAssets(") for fn in coop_fns
        )
        cooperative_close_is_per_asset_transfer = (
            any(fn.startswith("transfer(") for fn in coop_fns)
            and _cast_call(adjudicator, usdc, channel0_id, rpc) == 0
        )

        # -- openAndChallenge + earlySettle (E10: must revert, pays nothing -- out of scope)
        _forge_script("openAndChallenge()", rpc, env)
        _forge_script("earlySettle()", rpc, env)

        # wait out the challenge window, then settle
        _run(
            ["cast", "rpc", "evm_increaseTime", str(CHALLENGE_DURATION + 5), "--rpc-url", rpc], env, REPO_ROOT
        )
        _run(["cast", "rpc", "evm_mine", "--rpc-url", rpc], env, REPO_ROOT)

        custodian_usdc_before = _cast_balance(usdc, custodian, rpc)
        usdc2_holdings_before = _cast_call(adjudicator, usdc2, channel1_id, rpc)

        # -- settle (channel 1, two assets: the good one pays, the reverting one is skipped)
        settle_fns = _forge_script("settle()", rpc, env)
        custodian_usdc_after = _cast_balance(usdc, custodian, rpc)
        usdc_holdings_after = _cast_call(adjudicator, usdc, channel1_id, rpc)
        usdc2_holdings_after = _cast_call(adjudicator, usdc2, channel1_id, rpc)

        settle_first_asset_paid = (
            custodian_usdc_after - custodian_usdc_before == FORCED_HUB
        ) and usdc_holdings_after == 0
        settle_second_asset_holdings_unchanged = usdc2_holdings_after == usdc2_holdings_before
        settle_mentions_transfer_all_in_trace = any(fn.startswith("transferAllAssets(") for fn in settle_fns)
        settle_broadcast_is_per_asset_only = bool(settle_fns) and all(
            fn.startswith("transfer(") for fn in settle_fns
        )

        results = {
            "cooperative_close_is_per_asset_transfer": bool(cooperative_close_is_per_asset_transfer),
            "settle_broadcast_is_per_asset_only": bool(settle_broadcast_is_per_asset_only),
            "settle_first_asset_paid": bool(settle_first_asset_paid),
            "settle_second_asset_holdings_unchanged": bool(settle_second_asset_holdings_unchanged),
            "cooperative_close_used_conclude_all": bool(cooperative_close_used_conclude_all),
            "settle_mentions_transfer_all_in_trace": bool(settle_mentions_transfer_all_in_trace),
        }

        print(json.dumps(results))

        expected = {
            "cooperative_close_is_per_asset_transfer": True,
            "settle_broadcast_is_per_asset_only": True,
            "settle_first_asset_paid": True,
            "settle_second_asset_holdings_unchanged": True,
            "cooperative_close_used_conclude_all": False,
            "settle_mentions_transfer_all_in_trace": False,
        }
        ok = all(results[k] == expected[k] for k in expected)
        if not ok:
            sys.stderr.write("field mismatch:\n")
            for k in expected:
                if results[k] != expected[k]:
                    sys.stderr.write(f"  {k}: got {results[k]}, expected {expected[k]}\n")
        return 0 if ok else 1
    finally:
        anvil.terminate()
        try:
            anvil.wait(timeout=10)
        except subprocess.TimeoutExpired:
            anvil.kill()
        shutil.rmtree(WORKDIR, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
