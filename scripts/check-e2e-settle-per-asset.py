#!/usr/bin/env python3
"""arn-7de checker: `FixturenetScenario.s.sol`'s `settle()` pays each asset of a finalized
channel on its own when the single all-assets payout call (`transferAllAssets`) reverts on
one asset.

Drives the real `script/FixturenetScenario.s.sol` scenario (`setUpHub`, `openAndChallenge`,
`earlySettle`, `settle`) against a fresh local anvil node, against a finalized two-asset
channel whose second asset (a `RevertingTransferToken`, deployed by
`script/CheckSettlePerAssetSetup.s.sol`) always reverts on `transfer`. `transferAllAssets`
therefore reverts as a whole for this channel, and `settle()` must fall back to the
per-asset `transfer(assetIndex, ...)` path (`MultiAssetHolder.sol`).

Checks, by reading on-chain state (via `cast call`) before and after `settle()`:
  - first_asset_paid: the custodian's USDC balance increased by exactly the forced
    channel's hub allocation (FORCED_HUB) across `settle()`, and the channel's USDC
    holdings are fully drained -- i.e. the first (good) asset really was paid out, not
    just "didn't revert".
  - second_asset_holdings_unchanged: the channel's recorded holdings for the second
    (reverting) asset are identical before and after `settle()`.

Prints one JSON line: {"first_asset_paid": bool, "second_asset_holdings_unchanged": bool}.
Exits non-zero if either is false, or if any step fails.
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
# only, the same ones `stack/container-build/cerc-armada-nitro-foundry/armada-nitro-local`
# already uses as its own defaults.
DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
USER_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
DELEGATE_KEY = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
CHALLENGE_DURATION = 5
HUB_REVOCATION_DELAY = 60
FORCED_HUB = 50_000_000

WORKDIR = REPO_ROOT / "deployments" / "check-settle-per-asset"
FROST_SHARES_DIR = WORKDIR / "frost"
FROST_SIGNER = REPO_ROOT / "target" / "release" / "frost-signer"


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def _run(cmd: list[str], env: dict[str, str], cwd: pathlib.Path) -> str:
    result = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        sys.stderr.write(f"command failed: {' '.join(cmd)}\n")
        sys.stderr.write(result.stdout[-4000:])
        sys.stderr.write(result.stderr[-4000:])
        raise SystemExit(result.returncode)
    return result.stdout


def _forge_script(sig: str | None, rpc: str, env: dict[str, str], broadcast: bool = True) -> str:
    cmd = ["forge", "script", "script/FixturenetScenario.s.sol"]
    if sig:
        cmd += ["--sig", sig]
    cmd += ["--rpc-url", rpc, "--slow", "--ffi"]
    if broadcast:
        cmd += ["--broadcast"]
    return _run(cmd, env, REPO_ROOT)


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


def _keygen_frost_group() -> None:
    """Build the host frost-signer and keygen a 2-of-3 FROST group into FROST_SHARES_DIR. The
    setup script deploys the custodian with this group's key, and FixturenetScenario.s.sol signs
    the custodian's `execute` calls with two of its shares."""
    build = subprocess.run(
        ["cargo", "build", "--release", "-p", "frost-signer"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=900,
    )
    if build.returncode != 0:
        sys.stderr.write(build.stdout[-4000:])
        sys.stderr.write(build.stderr[-4000:])
        raise SystemExit(build.returncode)
    _run([str(FROST_SIGNER), "keygen", "--out", str(FROST_SHARES_DIR)], os.environ.copy(), REPO_ROOT)


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
                ["cast", "block-number", "--rpc-url", rpc],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
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

        # Deploy a fresh fixturenet-shaped environment with a second (always-reverts-on-
        # transfer) channel asset, and write manifest.json/deposits.json/keys in the shapes
        # FixturenetScenario.s.sol itself reads.
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
        channel_id = deposits["deposits"][1]["channelId"]

        # The real scenario, unmodified: authorize the hub, fund + challenge the forced
        # channel, prove the challenge window is enforced (E10), wait it out, then settle.
        _forge_script("setUpHub()", rpc, env)
        _forge_script("openAndChallenge()", rpc, env)
        _forge_script("earlySettle()", rpc, env)

        _run(
            ["cast", "rpc", "evm_increaseTime", str(CHALLENGE_DURATION + 5), "--rpc-url", rpc], env, REPO_ROOT
        )
        _run(["cast", "rpc", "evm_mine", "--rpc-url", rpc], env, REPO_ROOT)

        custodian_usdc_before = _cast_balance(usdc, custodian, rpc)
        usdc2_holdings_before = _cast_call(adjudicator, usdc2, channel_id, rpc)

        _forge_script("settle()", rpc, env)

        custodian_usdc_after = _cast_balance(usdc, custodian, rpc)
        usdc_holdings_after = _cast_call(adjudicator, usdc, channel_id, rpc)
        usdc2_holdings_after = _cast_call(adjudicator, usdc2, channel_id, rpc)

        first_asset_paid = (
            custodian_usdc_after - custodian_usdc_before == FORCED_HUB and usdc_holdings_after == 0
        )
        second_asset_holdings_unchanged = usdc2_holdings_after == usdc2_holdings_before

        print(
            json.dumps(
                {
                    "first_asset_paid": first_asset_paid,
                    "second_asset_holdings_unchanged": second_asset_holdings_unchanged,
                }
            )
        )
        return 0 if (first_asset_paid and second_asset_holdings_unchanged) else 1
    finally:
        anvil.terminate()
        try:
            anvil.wait(timeout=10)
        except subprocess.TimeoutExpired:
            anvil.kill()
        shutil.rmtree(WORKDIR, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
