# E9 Circuits in the image; deployer key from the deployment config

Depends on: E7 (merged). Read `docs/ENVIRONMENT.md` §3–§4 and §8, `stack/README.md`,
`stack/container-build/cerc-armada-nitro-env/`, `env/reconciler/modules/armada.py` (`_ensure_circuits_fetched`), and the
three job compose files in `stack/compose-jobs/`.

## Goal
A fresh fixturenet goes from `deploy create` to green gates with no manual step and no per-job 300 MB download.

## Deliver
- **Circuits in the image.** The image build downloads and verifies Armada's circuit build once. It uses the same
  release (`ship-armada/armada-circuits` `v0.1.0-dev`), the same tarball SHA-256, and the same per-file `SHA256SUMS`
  check as `_ensure_circuits_fetched`. The pins move into `env/sources.lock.json` as an `armada-circuits` entry. Jobs
  then use the circuits baked into the image; `_ensure_circuits_fetched` only verifies them and never downloads at job
  time. A wrong SHA-256 in the lock file must fail the image build.
- **Deployer key from laconic-so config.** The key comes from the deployment's configuration (the `config` section of
  the spec that `deploy init` writes, which laconic-so turns into the deployment's `config.env`), for example
  `DEPLOYER_KEY`.
  - The reconcile job writes `<state>/deployer.key` (mode 0600) from that variable if the file is absent.
  - If both are absent it fails naming the variable.
  - `stack/README.md` shows `deploy init --config DEPLOYER_KEY=<anvil key>` (or the equivalent laconic-so form; check
    `laconic-so deploy init --help`).
  - The key is never written into the repository or the image.

## Acceptance (paste output)
- Image build time. Check that the circuits are present in the image
  (`docker run --rm cerc/armada-nitro-env:local ls <circuits dir> | wc -l` shows 19 shapes).
- Negative case: a wrong circuits SHA-256 in a scratch copy of the lock file fails the build. Paste the failure line.
- On a fresh deployment created with the key in its config, with nothing placed by hand, paste the output of:
  - `run-job armada-env-reconcile` (show that the job no longer downloads circuits);
  - a second reconcile (nonce and manifest hash unchanged);
  - `run-job armada-env-verify` and `run-job armada-nitro-e2e`, with wall time per job before and after this change.
- Negative case: a deployment created without the key fails the reconcile job naming the variable.

## Out of scope
Sepolia key handling (E8), gate content changes (E10).
