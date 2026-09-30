#!/usr/bin/env python3
"""E13c acceptance entrypoint: run the reconciler's adopt mode on the fixturenet
with exactly one field of the all-adopt target mutated, and prove the reconciler
exits non-zero while naming the module / failed postcondition, and sends no
transactions (the deployer's on-chain nonce is unchanged).

Usage:
    python3 env/reconciler/tools/adopt_negative_case.py <case>

Cases (each mutates exactly one field of the all-adopt target):
    usdc-at-weth-address          usdc.proxy  = the already-deployed WETH address
    armada-at-no-code-address     armada.pool   = an address with no code on the fixturenet
    armada-nitro-wrong-group-key  armada_nitro's groupKeyX/Y swapped (wrong coordinates)
    lido-wsteth-points-at-steth   lido.wstETH   = lido.stETH (points at stETH, not the real wstETH)

The tool:
  1. Ensures /src/stablecoin-evm exists (same run setup as E13b).
  2. Generates the all-adopt target from the fixturenet's full-reconcile manifest
     via adopt_target.py (the E13a target, never hand-edited).
  3. Mutates the single field named by <case>.
  4. Reads the deployer's transaction count (nonce) before the run.
  5. Runs `python3 -m reconciler` (the reconcile-job invocation) against a fresh,
     empty state dir with the mutated target on the fixturenet.
  6. Reads the deployer's nonce after the run and checks it is unchanged.

Prints a single-line JSON verdict to stdout:
    {"reconciler_exit_code": int, "stderr_names_usdc": bool,
     "stderr_names_postcondition": bool, "stderr_names_armada": bool,
     "stderr_names_armada_nitro": bool, "stderr_names_group_key": bool,
     "stderr_names_lido": bool, "nonce_unchanged": bool}
Exits 0 on success (the run behaved as a negative case), non-zero otherwise.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Any, cast

# env/reconciler/tools/adopt_negative_case.py -> parents:
# parents[0]=tools, parents[1]=reconciler, parents[2]=env, parents[3]=repo root.
_TOOLS_DIR = Path(__file__).resolve().parent
_VERIFY_TOOL = _TOOLS_DIR / "verify_adopt_run.py"

# Anvil account 0: the deployer (EOA, no contract code on the fixturenet).
_NO_CODE_ADDRESS = "0x275f50342a1d25649c871a12633923f85f950b45"
# Correct FROST group-key coordinates for the fixturenet's hub custodian, carried
# from the E13a reference target (env/targets/fixturenet-adopt.json). The generated
# target omits these optional fields (written only when the manifest records the
# group-key scalar), so the wrong-group-key case injects them in swapped (wrong)
# order: X holds the Y coordinate and Y holds the X coordinate.
_GROUP_KEY_X_CORRECT = "0x4f6340cfdd930a6f54e730188e3071d150877fa664945fb6f18b56ce1c09"
_GROUP_KEY_Y_CORRECT = "0x802a5e67c00a70d85b9a088eac7cf5b9fb46ac5c0b2bd7d1e189fac210f6b7ef"


def _load_verify_tool() -> Any:
    """Load the E13b run-setup helpers from verify_adopt_run.py (same directory)
    so the nonce/addr/run helpers are reused, not duplicated (repo DRY doctrine)."""
    spec = importlib.util.spec_from_file_location("verify_adopt_run", _VERIFY_TOOL)
    if spec is None or spec.loader is None:
        raise SystemExit(f"could not load {str(_VERIFY_TOOL)}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _mutate_target(case: str, target: dict[str, Any]) -> None:
    """Mutate exactly one field of the all-adopt target named by *case*.

    Each case changes a single adopt field away from its correct value so the
    reconciler's adopt-mode verify fails (E13c negative cases,
    docs/tasks/E13-adopt-mode.md)."""
    if case == "usdc-at-weth-address":
        target["usdc"]["adopt"]["proxy"] = target["weth"]["adopt"]["address"]
    elif case == "armada-at-no-code-address":
        target["armada"]["adopt"]["pool"] = _NO_CODE_ADDRESS
    elif case == "armada-nitro-wrong-group-key":
        # The generated target omits the optional groupKeyX/Y fields (they're only
        # written when the manifest records the group-key scalar). Inject them in
        # swapped (wrong) order: X holds the Y coordinate, Y holds the X coordinate.
        # The reconciler's armada_nitro verify then fails on custodian.groupKeyX(),
        # naming the group key as the failed check.
        target["armada_nitro"]["adopt"]["groupKeyX"] = _GROUP_KEY_Y_CORRECT
        target["armada_nitro"]["adopt"]["groupKeyY"] = _GROUP_KEY_X_CORRECT
    elif case == "lido-wsteth-points-at-steth":
        target["lido"]["adopt"]["wstETH"] = target["lido"]["adopt"]["stETH"]
    else:
        raise SystemExit(
            f"unknown case {case!r}; expected one of "
            "usdc-at-weth-address, armada-at-no-code-address, "
            "armada-nitro-wrong-group-key, lido-wsteth-points-at-steth"
        )


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if len(args) != 1:
        print(
            json.dumps(
                {
                    "reconciler_exit_code": 1,
                    "stderr_names_usdc": False,
                    "stderr_names_postcondition": False,
                    "stderr_names_armada": False,
                    "stderr_names_armada_nitro": False,
                    "stderr_names_group_key": False,
                    "stderr_names_lido": False,
                    "nonce_unchanged": False,
                    "error": "usage: adopt_negative_case.py <case>",
                }
            )
        )
        return 1
    case = args[0]
    _verify = _load_verify_tool()

    # 1. Same run setup as E13b: ensure /src/stablecoin-evm for the verify steps.
    _verify._ensure_src_stablecoin()

    with tempfile.TemporaryDirectory() as scratch:
        scratch_path = Path(scratch)
        state_dir = scratch_path / "state"
        state_dir.mkdir(parents=True, exist_ok=True)
        target_path = scratch_path / "adopt-target.json"

        # 2. Generate the all-adopt target from the fixturenet manifest.
        _verify._generate_target(target_path)
        target = cast("dict[str, Any]", json.loads(target_path.read_text()))

        # 3. Mutate the single field for this case.
        _mutate_target(case, target)
        # Write the mutated target back (atomic, like the reconciler's manifest writes).
        tmp_path = target_path.with_name(target_path.name + ".tmp")
        tmp_path.write_text(json.dumps(target, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(tmp_path, target_path)

        # 4. Read the deployer nonce before the run.
        deployer_addr = _verify._deployer_address()
        nonce_before = _verify._read_nonce(deployer_addr)

        # 5. Run the reconciler with the mutated target (the reconcile-job invocation).
        exit_code, stdout, stderr = _verify._run_reconciler(state_dir, target_path)

        # 6. Read the nonce after the run.
        nonce_after = _verify._read_nonce(deployer_addr)

    # Naming checks over the reconciler's stderr (the FAILED line names the module
    # and the failed postcondition/check).
    stderr_names_usdc = "usdc" in stderr
    stderr_names_armada = "armada" in stderr
    stderr_names_armada_nitro = "armada_nitro" in stderr
    stderr_names_group_key = "groupKey" in stderr
    stderr_names_lido = "lido" in stderr
    # The reconciler prints `reconciler: FAILED: <module>: <postcondition>` on a
    # failed verify; a non-empty postcondition message means the failed check is
    # named in the output.
    failed_match = re.search(r"reconciler: FAILED: (\w+): (.+)", stderr)
    stderr_names_postcondition = failed_match is not None

    verdict = {
        "reconciler_exit_code": exit_code,
        "stderr_names_usdc": stderr_names_usdc,
        "stderr_names_postcondition": stderr_names_postcondition,
        "stderr_names_armada": stderr_names_armada,
        "stderr_names_armada_nitro": stderr_names_armada_nitro,
        "stderr_names_group_key": stderr_names_group_key,
        "stderr_names_lido": stderr_names_lido,
        "nonce_unchanged": nonce_before == nonce_after,
    }
    print(json.dumps(verdict))

    # Negative case passes when the reconciler exits non-zero AND the nonce is
    # unchanged (no transactions sent).
    return 0 if (exit_code != 0 and nonce_before == nonce_after) else 1


if __name__ == "__main__":
    raise SystemExit(main())
