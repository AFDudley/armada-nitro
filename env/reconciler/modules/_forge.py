"""Shared helper for reconciler modules that drive `forge script` against an
upstream source checked out inside the image, and parse its broadcast
artifact for the addresses and gas it spent.

Not a reconciler module itself: the leading underscore keeps
`importlib.import_module(f"reconciler.modules.{name}")` (env/reconciler/__main__.py,
driven by MODULE_ORDER) from ever loading this as one.
"""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

from reconciler.context import CastError, to_int


def run_broadcast(
    *,
    project_dir: Path,
    script_target: str,
    rpc_url: str,
    chain_id: int,
    env: dict[str, str],
    extra_args: tuple[str, ...] = (),
) -> dict:
    """Runs `forge script <script_target> --broadcast` in `project_dir`,
    with `env` merged over the reconciler process's own environment (so the
    deployer key and per-call parameters reach the script's `vm.env*`
    cheatcodes), and returns the parsed broadcast artifact:
    `<project_dir>/broadcast/<script file>/<chain_id>/run-latest.json`.
    """
    full_env = {**os.environ, **env}
    result = subprocess.run(
        ["forge", "script", script_target, "--rpc-url", rpc_url, "--broadcast", *extra_args],
        capture_output=True,
        text=True,
        cwd=str(project_dir),
        env=full_env,
    )
    if result.returncode != 0:
        raise CastError(
            f"forge script {script_target} failed (exit {result.returncode}): {result.stderr.strip()[-4000:]}"
        )
    script_file = script_target.split(":", 1)[0]
    broadcast_path = project_dir / "broadcast" / Path(script_file).name / str(chain_id) / "run-latest.json"
    return json.loads(broadcast_path.read_text())


def sum_gas_used(receipts: dict) -> int:
    return sum(to_int(r["gasUsed"]) for r in receipts.get("receipts", []))


def created_contract_address(receipts: dict, contract_name: str) -> str:
    """Address of the top-level CREATE (or CREATE2) transaction that
    deployed `contract_name` directly (not via a factory's internal call)."""
    for tx in receipts["transactions"]:
        if tx["transactionType"] in ("CREATE", "CREATE2") and tx["contractName"] == contract_name:
            return tx["contractAddress"]
    raise KeyError(f"no CREATE transaction for {contract_name!r} in broadcast artifact")


def additional_contract_addresses(receipts: dict, contract_name: str) -> list[str]:
    """Addresses of every `contract_name` deployed as a side effect of a
    top-level call (e.g. through a CREATE2 factory), in broadcast order."""
    addrs = []
    for tx in receipts["transactions"]:
        for ac in tx.get("additionalContracts", []):
            if ac["contractName"] == contract_name:
                addrs.append(ac["address"])
    return addrs
