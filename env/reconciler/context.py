"""Shared context and helpers passed to every reconciler module.

A module (`env/reconciler/modules/<name>.py`) exposes three functions:

    observe(ctx) -> observed
        Read the manifest and, if useful, the chain. Returns whatever the
        module's own apply() needs to decide what (if anything) to do; the
        framework does not interpret this value.

    apply(ctx, observed) -> (action, gasUsed)
        Deploy or configure only what is missing, updating `ctx.manifest`
        in place (the module owns its own keys in the manifest, e.g. the
        weth module writes manifest["assets"]["weth"]). `action` is one of
        "adopted", "present", "deployed", "configured". Not called when
        `ctx.verify_only` is set.

    verify(ctx, action) -> None
        Assert this module's postconditions (docs/ENVIRONMENT.md §6) against
        the chain, reading whatever address/state `ctx.manifest` now holds.
        Raise `ctx.fail(postcondition)` on failure. Must send no
        transactions when `action == "present"` (idempotent re-runs, and
        the read-only `armada-env-verify` gate, both rely on this).
"""
from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


class ReconcileError(Exception):
    """Raised by a module to fail its step; names the module and the
    postcondition (or step) that failed, so the framework can report both."""

    def __init__(self, module: str, postcondition: str):
        super().__init__(f"{module}: {postcondition}")
        self.module = module
        self.postcondition = postcondition


class CastError(RuntimeError):
    """A `cast` subprocess exited non-zero."""


def to_int(value: Any) -> int:
    """Coerce a JSON receipt field (hex string, decimal string, or int) to int."""
    if isinstance(value, str):
        return int(value, 16) if value.lower().startswith("0x") else int(value)
    return int(value)


def resolve_target_mode(module_config: dict) -> tuple[str, dict]:
    """A module's target entry is either {"deploy": {...params}} or
    {"adopt": {...params}}, never both. Returns (mode, params)."""
    has_deploy = "deploy" in module_config
    has_adopt = "adopt" in module_config
    if has_deploy and has_adopt:
        raise ValueError("target names both deploy and adopt")
    if has_deploy:
        return "deploy", module_config["deploy"] or {}
    if has_adopt:
        return "adopt", module_config["adopt"] or {}
    raise ValueError("target names neither deploy nor adopt")


@dataclass
class Context:
    """Per-run state shared by every module. One Context is built by
    __main__ and reused across modules; `module_name` is set by the
    framework before each module's steps run, so `ctx.fail()` and cast
    error messages name the right module."""

    rpc_url: str
    state_dir: Path
    key_file: Path
    target: dict
    manifest: dict
    verify_only: bool
    module_name: str = ""
    _deployer_key: str = field(default="", repr=False)
    _deployer_address: str = field(default="", repr=False)

    def fail(self, postcondition: str) -> ReconcileError:
        return ReconcileError(self.module_name, postcondition)

    # -- subprocess helpers ---------------------------------------------

    def _run(self, argv: list[str]) -> str:
        result = subprocess.run(argv, capture_output=True, text=True)
        if result.returncode != 0:
            raise CastError(
                f"cast/forge call failed (exit {result.returncode}, argv={argv}): {result.stderr.strip()}"
            )
        return result.stdout.strip()

    def cast(self, *args: str, rpc_url: str | None = None) -> str:
        """Run a read-only `cast` subcommand; returns stdout, stripped.
        `rpc_url` overrides the network being reconciled -- used by oracle
        postconditions that read a reference chain (mainnet, Sepolia)."""
        return self._run(["cast", *args, "--rpc-url", rpc_url or self.rpc_url])

    def cast_json(self, *args: str, rpc_url: str | None = None) -> Any:
        return json.loads(self.cast(*args, rpc_url=rpc_url))

    def forge(self, *args: str, cwd: str | None = None) -> str:
        result = subprocess.run(["forge", *args], capture_output=True, text=True, cwd=cwd)
        if result.returncode != 0:
            raise CastError(
                f"forge call failed (exit {result.returncode}, argv={args}): {result.stderr.strip()}"
            )
        return result.stdout.strip()

    # -- signer -----------------------------------------------------------

    @property
    def deployer_key(self) -> str:
        if not self._deployer_key:
            self._deployer_key = self.key_file.read_text().strip()
        return self._deployer_key

    @property
    def deployer_address(self) -> str:
        # cast wallet address is a pure offline computation; it takes no
        # --rpc-url (unlike every other cast subcommand this Context wraps).
        if not self._deployer_address:
            self._deployer_address = self._run(
                ["cast", "wallet", "address", "--private-key", self.deployer_key]
            )
        return self._deployer_address

    def send(self, *args: str) -> dict:
        """Sign and publish a transaction with the deployer key; returns the
        parsed JSON receipt (contractAddress, gasUsed, effectiveGasPrice, ...).
        Flags precede the positional TO/SIG/ARGS (or --create CODE) because
        cast's arg parser only recognizes them there."""
        out = self._run(
            [
                "cast",
                "send",
                "--private-key",
                self.deployer_key,
                "--json",
                "--rpc-url",
                self.rpc_url,
                *args,
            ]
        )
        return json.loads(out)
