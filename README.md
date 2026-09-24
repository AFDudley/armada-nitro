# nitro-railgun

Nitro state channels funded from and settled to Armada shielded notes. This is the v1.5 construction in the
armada-laconic spec (ADR-0015/0016, `engineering/shielded-nitro-bridge-design.md` §3):

- **nitro-railgun adjudicator** — go-nitro's ForceMove dispute machine plus
  (a) note-native custody: a channel is funded by an Armada unshield bound to the channel, and an allocation is paid
  out by shielding a fresh note;
  (b) EIP-1271 participants, so a hub's channel participant is its custodian contract rather than an EOA.
- **hub custodian** — the hub's stable on-chain principal. A FROST(secp256k1, KECCAK-256) group key authorizes every
  cold operation; hot delegate ECDSA keys sign channel states and are checked through `isValidSignature`.

Target: Ethereum Sepolia against Armada's `demo3` deployment. Local testing runs on a laconic stack-orchestrator
stack (`stack/`).

## Provenance

| Path | Source | Pin |
|---|---|---|
| `src/nitro/` | go-nitro `packages/nitro-protocol/contracts` (MIT) | `435eb2b`; first vendored unmodified, changes are separate commits |
| `lib/exit-format` | statechannels/exit-format (MIT) | `43450d8` (npm 0.2.0) |
| `lib/openzeppelin-contracts` | OpenZeppelin (MIT) | v4.9.3 |
| `lib/frost-secp256k1-evm` | StackOverflowExcept1on/frost-secp256k1-evm (MIT), FROST-secp256k1-KECCAK256 verifier | `65d03d0` |
| `lib/armada-poc` | ship-armada/armada-poc — pool for the tests and the local stack | `532bc064` |

## Contract behavior

**Funding from a note.** `depositFromNote(channelId, expectedHeld, [tx])` submits one Armada unshield
(`UnshieldType.NORMAL`) to the adjudicator with `adaptContract` = the adjudicator and
`adaptParams` = `depositBinding(channelId, expectedHeld)`. Both are public inputs of the proof, and the pool accepts
the transaction only from `adaptContract`, so an unshield funds exactly one channel at one holding and cannot be
submitted around the adjudicator. Anyone (a broadcaster) may submit it. The unshield amount is public (Design A).

**Payout to a note.** An allocation with `allocationType` 3 (`SHIELD`) is paid by shielding a fresh note:
`destination` is the recipient's note public key, `metadata` is `abi.encode(ShieldCiphertext)`. All `SHIELD`
allocations of one exit go into a single `pool.shield` call. Armada's shield fee is deducted from the note. Other
allocation types pay out as in go-nitro. A malformed `SHIELD` allocation (npk outside the field, bad metadata) makes
`pool.shield` revert, which blocks `transferAllAssets` for that outcome; other parties use `transfer` with their own
allocation indices.

**Contract participants.** A participant authorizes a state or challenge either as the ECDSA signer or, for a
contract, through EIP-1271 over the same EIP-191 digest. The probe is a staticcall capped at 100k gas that reads one
word, so a participant contract can only refuse its own signatures. Counterparties still rely on the custodian's
code: a custodian that stops accepting its own delegate's signatures blocks the counterparty from proving hub-signed
states. Clients should open channels only with custodians whose code hash they have verified.

**Hub custodian.** `execute(target, value, data, groupSignature)` performs one call authorized by the FROST group
key over `operationHash(nonce, …)`, which binds chain id, custodian address and nonce. Delegate and group-key
administration are `onlySelf` and reached through `execute`. `revokeDelegate` takes effect after `revocationDelay`;
a counterparty holding a state signed by that delegate must register it (challenge or checkpoint) before then, so
`revocationDelay` must exceed every channel's challenge duration plus the counterparty's response time.

**Removed from go-nitro.** `setL2ToL1` and the `mirror*` functions (the L2 bridge stub): the owner-set channel map
let the owner pay out any channel's holdings under another channel's outcome.

## Build and test

```sh
git clone --recursive https://github.com/AFDudley/nitro-railgun
forge build
forge test
```

Tests run Armada's real `PrivacyPool` with the circomlib Poseidon libraries (`lib/armada-poc/lib/poseidon_bytecode.json`)
etched at the addresses linked in `foundry.toml`; only the SNARK check is bypassed (`testingMode`).
`test/fixtures/frost-2of3.json` is a 2-of-3 threshold signature from the `frost-secp256k1-evm` crate; regenerate it
with `cargo run --manifest-path tools/frost-fixture/Cargo.toml`.

## Local stack (laconic stack-orchestrator)

`stack/` is an external stack: an anvil pod and two jobs. `deploy` deploys Armada's pool (testing mode), a mock USDC,
the adjudicator and a custodian. `scenario` runs a cooperative close, then a force-close that waits out a real
challenge window, then verifies chain state and the pool's `Shield` logs; it can be rerun on the same deployment.

```sh
S=$PWD/stack/stacks/nitro-railgun
laconic-so --stack $S build-containers
laconic-so --stack $S deploy init --output nitro-railgun-spec.yml
laconic-so --stack $S deploy create --spec-file nitro-railgun-spec.yml --deployment-dir ~/deployments/nitro-railgun
laconic-so deployment --dir ~/deployments/nitro-railgun start
laconic-so deployment --dir ~/deployments/nitro-railgun run-job nitro-railgun-deploy
laconic-so deployment --dir ~/deployments/nitro-railgun run-job nitro-railgun-scenario
```

The jobs use anvil's published development keys and a fixed FROST scalar; `CHALLENGE_DURATION` (default 15 s) and
`HUB_REVOCATION_DELAY` (default 60 s) are read from the job environment.

## Sepolia

`script/Deploy.s.sol` deploys the adjudicator, `ConsensusApp` and one custodian against an existing pool and writes
`deployments/<chainId>.json`:

```sh
ARMADA_POOL=0x5f3324b47b3CFf937BB67C30B362898E193e5216 \
HUB_GROUP_KEY_X=0x… HUB_GROUP_KEY_Y=0x… HUB_REVOCATION_DELAY=604800 \
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC --broadcast --private-key $KEY
```

Simulated against Sepolia `demo3`: about 8.6M gas. The group key comes from the hub's FROST DKG. Funding a channel
on Sepolia needs a real unshield proof whose `adaptContract`/`adaptParams` are set as above; the demo3 pool verifies
proofs.
