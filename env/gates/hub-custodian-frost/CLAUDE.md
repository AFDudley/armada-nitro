# env/gates/hub-custodian-frost/

Gate that proves the fixturenet's hub custodian is deployed with the FROST group
public key (X, Y) read from a frost-signer key file in the deployment's state
directory, instead of a single held scalar (E14b).

The check logic runs inside the `armada-custodian-frost` laconic-so job
(`stack/compose-jobs/docker-compose-armada-custodian-frost.yml`, registered in
`stack/stacks/armada-nitro-fixturenet/stack.yml`), not as a host process -- the
deployment's data directory is root-only (arn-8e9), so nothing outside a container
mounting `armada_env:/env` can read or write it.

- `verify.py` — a thin runner (`python3 verify.py {match|mismatch}`): syncs the
  deployment's job files (`laconic-so deploy create --update`, mirroring
  `scripts/run-armada-watchtower-scenario.sh`), runs the check job via
  `laconic-so deployment --dir <deployment> run-job armada-custodian-frost` with
  the case passed as `$CUSTODIAN_FROST_CASE`, and prints the job's one-line JSON
  report unchanged. verify.py itself never touches the state directory.
- The job (self-contained: the check script is embedded in the compose file's
  command block, not baked into the env image, so it needs no image rebuild) runs
  inside `cerc/armada-nitro-env`, with `/env` mounted from the `armada_env` volume:
  - `match`: confirms the target config uses the key-file parameter, ensures a
    frost-signer key file exists in `/env` (writing one with the on-chain X, Y if
    missing), runs the reconciler (the setup step that deploys/verifies the
    custodian with the file's X, Y), and reports `config_uses_keyfile_param`,
    `onchain_key_matches_file`, `manifest_records_key`, `overall_positive_case_passed`.
  - `mismatch`: re-checks the deployment against a *different* key file (X, Y
    incremented from the on-chain key) and reports `verify_exit_code` (non-zero)
    and `failure_names_mismatch` (the reconciler's failure message names which group
    key value it expected and which it found).

The deployment defaults to the operator-managed fixturenet (`~/deployments/armada-fixturenet-e12`);
override with `$ARMADA_DEPLOYMENT_DIR`. `$LACONIC_SO` / `$LACONIC_SO_PYTHON` override the
orchestrator binary and its interpreter.
