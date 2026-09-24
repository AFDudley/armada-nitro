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
| `lib/armada-poc` | ship-armada/armada-poc — pool used by tests only | `532bc064` |

## Build and test

```sh
git clone --recursive https://github.com/AFDudley/nitro-railgun
forge build
forge test
```
