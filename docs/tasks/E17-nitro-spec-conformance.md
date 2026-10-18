# E17 Nitro specification conformance

Depends on: E16. Later work: not scheduled. Read `README.md` (vendoring table), `src/nitro/` (vendored from
cerc-io/go-nitro `packages/nitro-protocol/contracts` at `435eb2b`, v0.1.7, commit `8edacc1`), `lib/exit-format`, and
`git log -- src/nitro` for the local edits made since.

## Goal
Every clause of the published Nitro and ForceMove specification has a test that proves the vendored contracts meet it,
and every local edit to `src/nitro/` is either covered by a clause or recorded as an addition to the specification.

## Specification sources
The most recent statement of the protocol for the code at `435eb2b` is:
- **docs.statechannels.org** (operational API, generated from statechannels/go-nitro `docs/` on `main`):
  `challenge`/`checkpoint`/`conclude`, `transfer`/`transferAllAssets`/`reclaim`, the exit-format Outcome.
- **SATP** (Stewart et al., 2022-09-28, https://statechannels.github.io/satp_paper/satp.pdf): the design. The docs'
  research-papers page states that SATP matches the current implementation.

Background only, out of date per that same page: ForceMove (Close and Stewart, 2018,
https://magmo.com/force-move-games.pdf) and Nitro Protocol (Close, 2019, IACR ePrint 2019/219,
https://magmo.com/nitro-protocol.pdf).

## Deliver
- **C1 · Sources in the repository.** Copy each source above into `docs/references/nitro/`, with its URL, retrieval
  date and checksum. A source that cannot be copied is recorded by URL and date.
- **C2 · Clause list.** `docs/references/nitro/clauses.md`: every testable clause of the operational docs and SATP, each
  with its source section and the code site (`file:line`) that implements it, or "absent".
- **C3 · Clause tests.** One forge test (or a fixturenet check, where the clause needs a live chain) per clause.
- **C4 · Local edits.** Each commit to `src/nitro/` after `8edacc1` is mapped to a clause, or listed as an addition to
  the specification with its reason.
- **C5 · Differences and silences.** Every difference between the specification and the code, and every point where the
  specification is silent, listed with its code site.
- **C6 · Baseline check.** `src/nitro/` at `8edacc1` byte-matches cerc-io/go-nitro `packages/nitro-protocol/contracts`
  at `435eb2b`.

## Test rule
- **A clause the code meets:** prove its test with a mutation. A change to the code that breaks the clause makes the
  test fail, and the real code passes. The mutated code is never committed.
- **A clause the code does not meet:** red first. Commit the failing test, then the fix.
- **Expected:** 0 clauses unmet. Each unmet clause is a finding, filed on its own.

## Acceptance (paste output)
- The clause list (C2), with a count of clauses met, unmet and absent.
- For each met clause: the test, the mutation, and the test's failure on the mutation and pass on the real code.
- For each unmet clause: the red commit and the green commit.
- The baseline check result (C6).

## Out of scope
Changes to the specification. New ForceMove apps. Upstream changes after `435eb2b`.
