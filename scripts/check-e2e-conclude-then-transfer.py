#!/usr/bin/env python3
"""N3 (arn-7c4) e2e checker: `script/LocalScenario.s.sol`'s `cooperativeClose()` settles a
channel against a REAL deployed ArmadaNitroAdjudicator + Armada PrivacyPool + MockUSDCV2 on a
fresh local anvil node, using exactly the finalize-only `conclude()` + per-asset
`transfer(assetIndex, ...)` path N3 requires -- never the bulk
`concludeAndTransferAllAssets`/`transferAllAssets` functions.

Checks, by reading `cooperativeClose()`'s own forge-script broadcast file:
  - calls_conclude: the broadcast includes a `conclude(` call (ForceMove's plain finalize).
  - calls_transfer: the broadcast includes a `transfer(` call (the per-asset payout), with a
    successful (non-reverted) on-chain receipt.
  - no_bulk_calls: the broadcast includes neither `concludeAndTransferAllAssets(` nor
    `transferAllAssets(`.

And, by reading on-chain state (via `cast call`) after `cooperativeClose()`:
  - holding_zeroed: the channel's recorded USDC holding is empty (bytes32(0)) -- the single
    asset was actually paid out, not left as a dangling commitment.

Prints one JSON line with all four fields. Exits non-zero if any is false, or if any step
fails.
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

# anvil's well-known default dev-account private keys -- local chain only, the same ones
# stack/container-build/cerc-armada-nitro-foundry/armada-nitro-local already uses as defaults.
DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
USER_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
DELEGATE_KEY = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
HUB_GROUP_SCALAR = "0xa4ddf31f7f32ba696f14ce50ecf3f21e3e100e83bdf47966e7b07468e9500b6e"
CHALLENGE_DURATION = "15"
HUB_REVOCATION_DELAY = "60"

WORKDIR = REPO_ROOT / "deployments" / "check-e2e-conclude-then-transfer"


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def _run(cmd: list[str], env: dict[str, str], cwd: pathlib.Path) -> "subprocess.CompletedProcess[str]":
    r = subprocess.run(cmd, env=env, cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"command failed: {' '.join(cmd)}", file=sys.stderr)
        print(r.stdout, file=sys.stderr)
        print(r.stderr, file=sys.stderr)
        raise SystemExit(1)
    return r


def _wait_for_rpc(rpc: str, timeout: float = 20.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        r = subprocess.run(["cast", "block-number", "--rpc-url", rpc], capture_output=True)
        if r.returncode == 0:
            return
        time.sleep(0.2)
    raise SystemExit(f"anvil never came up at {rpc}")


def _json_field(path: pathlib.Path, key: str) -> str:
    return str(json.loads(path.read_text())[key])


def main() -> int:
    if WORKDIR.exists():
        shutil.rmtree(WORKDIR)
    WORKDIR.mkdir(parents=True)

    port = _free_port()
    rpc = f"http://127.0.0.1:{port}"
    anvil = subprocess.Popen(
        ["anvil", "--host", "127.0.0.1", "--port", str(port), "--chain-id", "31337", "--hardfork", "osaka"],
        cwd=WORKDIR,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        _wait_for_rpc(rpc)

        env = {
            **os.environ,
            "DEPLOYER_KEY": DEPLOYER_KEY,
            "USER_KEY": USER_KEY,
            "DELEGATE_KEY": DELEGATE_KEY,
            "HUB_GROUP_SCALAR": HUB_GROUP_SCALAR,
            "CHALLENGE_DURATION": CHALLENGE_DURATION,
            "HUB_REVOCATION_DELAY": HUB_REVOCATION_DELAY,
        }

        deployments_dir = REPO_ROOT / "deployments"
        deployments_dir.mkdir(exist_ok=True)
        armada_json = deployments_dir / "31337-armada.json"
        nitro_json = deployments_dir / "31337.json"
        for p in (armada_json, nitro_json):
            if p.exists():
                p.unlink()

        _run(["forge", "script", "script/LocalArmada.s.sol", "--rpc-url", rpc, "--broadcast"], env, REPO_ROOT)
        pool_addr = _json_field(armada_json, "pool")
        usdc_addr = _json_field(armada_json, "usdc")

        group_key = subprocess.run(
            ["cast", "wallet", "public-key", "--raw-private-key", HUB_GROUP_SCALAR],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        deploy_env = {
            **env,
            "ARMADA_POOL": pool_addr,
            "HUB_GROUP_KEY_X": "0x" + group_key[2:66],
            "HUB_GROUP_KEY_Y": "0x" + group_key[66:130],
            "ARMADA_ASSETS": usdc_addr,
        }
        _run(
            [
                "forge",
                "script",
                "script/Deploy.s.sol",
                "--rpc-url",
                rpc,
                "--broadcast",
                "--private-key",
                DEPLOYER_KEY,
            ],
            deploy_env,
            REPO_ROOT,
        )
        adjudicator_addr = _json_field(nitro_json, "adjudicator")

        _run(
            [
                "forge",
                "script",
                "script/LocalScenario.s.sol",
                "--sig",
                "setUpHub()",
                "--rpc-url",
                rpc,
                "--broadcast",
            ],
            env,
            REPO_ROOT,
        )
        _run(
            [
                "forge",
                "script",
                "script/LocalScenario.s.sol",
                "--sig",
                "cooperativeClose()",
                "--rpc-url",
                rpc,
                "--broadcast",
            ],
            env,
            REPO_ROOT,
        )

        bcast_path = (
            REPO_ROOT / "broadcast" / "LocalScenario.s.sol" / "31337" / "cooperativeClose-latest.json"
        )
        bcast = json.loads(bcast_path.read_text())
        functions = [t.get("function", "") for t in bcast["transactions"]]
        receipts = bcast.get("receipts", [])

        calls_conclude = any(fn.startswith("conclude(") for fn in functions)
        no_bulk_calls = not any(
            fn.startswith("concludeAndTransferAllAssets(") or fn.startswith("transferAllAssets(")
            for fn in functions
        )
        transfer_indices = [i for i, fn in enumerate(functions) if fn.startswith("transfer(")]
        calls_transfer = bool(transfer_indices) and all(
            i < len(receipts) and receipts[i].get("status") == "0x1" for i in transfer_indices
        )

        user_addr = subprocess.run(
            ["cast", "wallet", "address", "--private-key", USER_KEY],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        hub_custodian_addr = _json_field(nitro_json, "hubCustodian")
        consensus_app_addr = _json_field(nitro_json, "consensusApp")
        nonce = (deployments_dir / "31337-scenario-cooperative-nonce").read_text().strip()

        fixed_part_encoded = subprocess.run(
            [
                "cast",
                "abi-encode",
                "f(address[],uint64,address,uint48)",
                f"[{user_addr},{hub_custodian_addr}]",
                nonce,
                consensus_app_addr,
                CHALLENGE_DURATION,
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        channel_id = subprocess.run(
            ["cast", "keccak", fixed_part_encoded],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()

        holding = subprocess.run(
            [
                "cast",
                "call",
                "--rpc-url",
                rpc,
                adjudicator_addr,
                "holdings(address,bytes32)(bytes32)",
                usdc_addr,
                channel_id,
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        holding_zeroed = holding == "0x" + "0" * 64

        result = {
            "calls_conclude": calls_conclude,
            "calls_transfer": calls_transfer,
            "no_bulk_calls": no_bulk_calls,
            "holding_zeroed": holding_zeroed,
        }
        print(json.dumps(result))
        return 0 if all(result.values()) else 1
    finally:
        anvil.terminate()
        anvil.wait(timeout=5)


if __name__ == "__main__":
    sys.exit(main())
