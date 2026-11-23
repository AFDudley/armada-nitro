# PoolSol

`PoolSol.sol` is the pool contract that armada-laconic-mono emits from its Lean declaration
(`armada-sol/ArmadaSol/PoolContract.lean`, through `armada-charter`'s `contract` command). The file
is a copy of `armada-sol/out/PoolSol.sol`, because the monorepo is private and the image clones
sources anonymously. Do not edit it here.

`provenance.json` records:

- `monorepoCommit`, `source`, `sourceSha256`: the commit and the file that this copy comes from;
- `solc`: the compiler profile (the image's `solc-pool` stage supplies solc 0.8.31);
- `statement`, `runtimeSha256`, `runtimeLength`: the Lean file that holds the runtime bytecode the
  bytecode statements are about, and the SHA-256 of that runtime with zero bytes at the link and
  immutable offsets;
- `links`, `immutables`: those byte offsets.

The `armada_sol` reconciler module (`env/reconciler/modules/armada_sol.py`) refuses a copy whose
SHA-256 differs from `sourceSha256`. Its `verify` compares the deployed runtime with
`runtimeSha256`.

To take a new version: copy `armada-sol/out/PoolSol.sol` from the monorepo at the new commit, and
write `provenance.json` again from `armada-sol/ArmadaSol/Bytecode/Pool/Code.lean` at that commit
(`runtimeHex`, `linkPoseidonT3`, `linkPoseidonT4`, `imm_feeAdmin`, `imm_treasury`, `imm_maxBatch`).

`env/gates/armada-sol/scenarios.ts` runs one scenario for each external function of PoolSol on the fixturenet and
prints one verdict line for each (`stack/compose-jobs/docker-compose-armada-sol-scenario.yml`).
