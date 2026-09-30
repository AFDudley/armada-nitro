# env/gates/hub-custodian-frost/

Gate that proves the fixturenet's hub custodian is deployed with the FROST group
public key (X, Y) read from a frost-signer key file in the deployment's state
directory, instead of a single held scalar (E14b).

- `verify.py` — the gate entry point (`python3 verify.py {match|mismatch}`).
  - `match`: confirms the target config uses the key-file parameter, ensures a
    frost-signer key file exists in the state dir (writing one with the on-chain
    X, Y if missing), runs the reconciler (the setup step that deploys/verifies the
    custodian with the file's X, Y), and reports `config_uses_keyfile_param`,
    `onchain_key_matches_file`, `manifest_records_key`, `overall_positive_case_passed`.
  - `mismatch`: re-checks the deployment against a *different* key file (X, Y
    incremented from the on-chain key) and reports `verify_exit_code` (non-zero)
    and `failure_names_mismatch` (the reconciler's failure message names which group
    key value it expected and which it found).

The state directory defaults to the operator-managed fixturenet deployment's
`data/armada_env`; override with `$ARMADA_STATE_DIR`. Host RPC defaults to the
target's `network.hostRpcUrl`; override with `$ARMADA_RPC_URL`.
