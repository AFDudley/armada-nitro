# Nitro and ForceMove specification sources

The specification against which `src/nitro/` is checked (task E17, `docs/tasks/E17-nitro-spec-conformance.md`).
`clauses.md` lists the testable clauses taken from these sources.

All sources were retrieved on 2026-10-18 (20:51 UTC). The copies are in `sources/`. They are kept for internal
reference in this private repository; each remains under its authors' terms.

## Authoritative sources

| # | Source | Date | Role | URL | Copy |
|---|---|---|---|---|---|
| S4 | docs.statechannels.org, protocol tutorial pages 0010–0080 and research-papers | Live site, 2026-10-18 | Operational specification. Generated from statechannels/go-nitro `docs/` on `main`, the upstream of the vendored contracts. It names the functions the code exposes. | https://docs.statechannels.org/ | `sources/docs.statechannels.org/*.html` |
| S3 | SATP: a simple and scalable protocol for virtual state channel networks (Stewart, Kennedy, Kerzhner, Knee, Geihs, Stammler) | 2022-09-28 | Design specification. The docs' research-papers page states that it matches the current implementation. | https://statechannels.github.io/satp_paper/satp.pdf (returned 404 on 2026-10-18; retrieved through web.archive.org) | `sources/satp-2022.pdf` |

## Background sources (out of date per the docs' research-papers page)

| # | Source | Date | URL | Copy |
|---|---|---|---|---|
| S1 | ForceMove: an n-party state channel protocol (Close, Stewart) | 2018-11-20 | https://magmo.com/force-move-games.pdf | `sources/forcemove-2018.pdf` |
| S2 | Nitro Protocol (Close), IACR ePrint 2019/219 | 2019-02-24 | https://magmo.com/nitro-protocol.pdf (byte-identical to the ePrint copy) | `sources/nitro-2019-219.pdf` |
| S5 | nitro-protocol CHANGELOG, statechannels/go-nitro `main` | stops at 0.17.3, 2021-08-26 | statechannels/go-nitro `packages/nitro-protocol/CHANGELOG.md` | `sources/nitro-protocol-CHANGELOG.md` |

## Code under check

`src/nitro/` is cerc-io/go-nitro `packages/nitro-protocol/contracts` at `435eb2b` (v0.1.7), vendored unmodified in
`8edacc1` (`README.md`). `lib/exit-format` is statechannels/exit-format `43450d8`.

## Checksums (sha256)

```
a546ba7c76ea039cfafa81e4c5840eec9fde456187f0de759344ec11598df407  sources/forcemove-2018.pdf
4330ffb53d713721f84a53200519af7f92f3254306e81acae0d5fc2e616fb04b  sources/nitro-2019-219.pdf
7a5faa2ebe44dfb884d3a90d9e3e9b3a33f7291b4841a51a1b4333476cfb64d5  sources/satp-2022.pdf
a3acc2807dce64623cdffa6c21a1a3856a16bdad1c1e5ef356f52648a3fa0621  sources/nitro-protocol-CHANGELOG.md
3316282e5c7a5daf86e9c19eccb12d2a6e946f2e0af8cae4814340e5315435ae  sources/docs.statechannels.org/index.html
5e16a1a791ad9769ed3dacb86e0630b5ad823431287d00facb52651de9b6e061  sources/docs.statechannels.org/protocol-tutorial_0010-states-channels_.html
6eca11c8beb507ecebf64eaea9575b854a90a4bd1e17229d240ddab88213def6  sources/docs.statechannels.org/protocol-tutorial_0020-execution-rules_.html
d77c7401dde62e50478f34c1340e0b5f9317a641211de09c879d43ee84d40574  sources/docs.statechannels.org/protocol-tutorial_0030-outcomes_.html
83061262f2d919da738b7fa248114b83bd3bf7be66f60ab9f3e1c44ee4513826  sources/docs.statechannels.org/protocol-tutorial_0040-lifecycle-of-a-channel_.html
4bd7bcbc3b0252cf0057c756be29c55466ace877586506be143bff17964d07f5  sources/docs.statechannels.org/protocol-tutorial_0060-funding-a-channel_.html
143cb31d589cb3940ce1e4bdca8e7568fed2564ffc613936644c913af9774995  sources/docs.statechannels.org/protocol-tutorial_0070-finalizing-a-channel_.html
894d3c93de16afe018f06a92eb8e4b494b4b0294254a4267ebdadf1944e4e806  sources/docs.statechannels.org/protocol-tutorial_0080-defunding-a-channel_.html
6aaccd606d386a73eb6af7abaad13cdb49197e5e9e008d23ad1949dddbfc98a3  sources/docs.statechannels.org/research-papers_.html
```
