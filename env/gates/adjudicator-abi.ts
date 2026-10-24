// ABOUTME: Loads the ArmadaNitroAdjudicator ABI from its compiled artifact, the one rule every
// ABOUTME: gate script that calls depositFromNote must share, never a hand-written per-gate copy.

/**
 * The adjudicator ABI, loaded from the compiled artifact, never hand-written: a literal copy of
 * the function signatures drifts every time the contract changes (the R1/P2a rewrites added
 * `ownerField` and `publicOutputs` to `BoundParams` -- a hand-written copy that predates them
 * computes a selector matching nothing in the deployed contract, so every call falls through to
 * Solidity's default revert: empty data, no sub-call). `stack/container-build/
 * cerc-armada-nitro-env/Dockerfile`'s `contracts` stage already runs `forge build` for this repo
 * and copies `/src/armada-nitro/out` into the image, so the artifact is always present by the
 * time a job runs; this never falls back to a literal ABI -- a missing artifact is a loud
 * failure, naming the path, not a silent empty ABI.
 *
 * Every gate script that imports this module is copied, at job run time, into
 * `/src/armada-poc/scripts/gates/` alongside this file (its own compose job or driver script's
 * `cp` step copies both), so the same-directory import `./adjudicator-abi` resolves regardless
 * of which gate copied it.
 */

import * as fs from "fs";

const ADJUDICATOR_ARTIFACT_PATH =
  process.env.ADJUDICATOR_ARTIFACT_PATH ||
  "/src/armada-nitro/out/ArmadaNitroAdjudicator.sol/ArmadaNitroAdjudicator.json";

export function loadAdjudicatorAbi(): unknown[] {
  if (!fs.existsSync(ADJUDICATOR_ARTIFACT_PATH)) {
    throw new Error(
      `adjudicator-abi.ts: compiled adjudicator artifact not found at ` +
        `${ADJUDICATOR_ARTIFACT_PATH}. Run forge build in /src/armada-nitro first (the job's ` +
        `own image already does this at build time); set ADJUDICATOR_ARTIFACT_PATH to point ` +
        `at a different artifact if this script runs outside that image. A hand-written ABI ` +
        `is not a fallback -- it drifts every time the contract changes.`,
    );
  }
  const artifact = JSON.parse(
    fs.readFileSync(ADJUDICATOR_ARTIFACT_PATH, "utf-8"),
  );
  if (!Array.isArray(artifact.abi)) {
    throw new Error(
      `adjudicator-abi.ts: ${ADJUDICATOR_ARTIFACT_PATH} has no "abi" array -- not a forge artifact.`,
    );
  }
  return artifact.abi as unknown[];
}
