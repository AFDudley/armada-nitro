# E13 Exercise adopt mode on the fixturenet

Depends on: E12. Read `docs/ENVIRONMENT.md` §4 (deploy vs adopt), `docs/tasks/E8-sepolia.md`, and every module's
adopt branch in `env/reconciler/modules/`.

## Goal
Every module's `adopt` path has run and been seen failing, so that E8 (Sepolia, which adopts WETH, USDC, CCTP, Lido and
Armada) is not the first time those code paths execute.

## Deliver
- `env/targets/fixturenet-adopt.json`: the same network, with every module in `adopt` mode, taking the addresses from a
  manifest produced by a full fixturenet reconcile.
  - A small script, `env/reconciler/tools/adopt_target.py <manifest> <out>`, generates this target file; it is not
    edited by hand.
  - Adopt parameters match what `docs/tasks/E8-sepolia.md` expects for Sepolia. For Lido, adopt uses the relaxed
    postconditions E8 describes (`stETH()` link, `stEthPerToken() > 0`), because Sepolia's Lido has a live oracle.
- Run the reconciler with that target against a fresh state directory (`--state` pointing at an empty dir), on the same
  chain.
  - Every module reports `adopted`, sends no transactions, and writes a manifest whose addresses equal the source
    manifest's.
  - `verify` passes for all modules.
- Unit-level: a module in adopt mode never calls its deploy path. Show this with a test that makes the deploy path
  raise and runs adopt.

## Acceptance (paste output)
- The adopt run's output.
- Deployer nonce before and after (unchanged).
- `diff` of the address fields of the two manifests (empty).

Negative cases, each seen failing; paste the lines:
- (a) Adopt `usdc` at the WETH address: fails naming the postcondition, and does not deploy.
- (b) Adopt `armada` at an address with no code: fails.
- (c) Adopt `armada_nitro` with a wrong group key: fails naming it.
- (d) Adopt `lido` with `wstETH` pointing at stETH: fails.

## Out of scope
Running against Sepolia (E8).
