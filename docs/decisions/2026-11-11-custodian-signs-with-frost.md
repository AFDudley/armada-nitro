# 2026-11-11: The hub custodian signs channel states with its own FROST group key

Status: decision.

## The rule

The hub custodian is a smart wallet. Its own FROST group key signs every
channel state. `HubCustodian.isValidSignature` verifies a FROST signature by
the group key. The custodian has no delegate path and no hot key.

## Why a delegate key is not needed

The operator's requirement is a DSS (threshold-key) construction for the hub,
for key security reasons. The operator did not ask for a delegate key.

A past "hot delegate" construction gave two reasons for a delegate key. Both
reasons are false.

First reason given: the adjudicator cannot verify a FROST signature. This is
false. The adjudicator already verifies EIP-1271 contract participants
(`src/nitro/libraries/NitroUtils.sol`, `isAuthorizedBy`). The custodian can
verify any signature scheme it chooses inside `isValidSignature`.

Second reason given: a FROST signing round is too slow for a channel state.
This is false. No speed requirement exists for a channel state signature. A
FROST signing round among t signers takes one network round trip. A round
trip between poorly distributed data centres takes tens to hundreds of
milliseconds. Ethereum's block time is 12 seconds. The round trip is far
below the block time.

## The encoding

The adjudicator calls `ecrecover` on a 65-byte signature first
(`NitroUtils.recoverSigner`). Only on a mismatch does the adjudicator pass
`abi.encodePacked(r, s, v)` to `isValidSignature`. A FROST signature fits this
65-byte shape:

- `r` holds the nonce point's x-coordinate.
- `s` holds the FROST response `z`.
- `v` holds the nonce point's y-parity, encoded as 27 or 28.

The adjudicator needs no change for this encoding.

## Reuse of the existing verifier

`execute` already verifies a FROST signature with `FROST.verifySignature`
from `lib/frost-secp256k1-evm`. `isValidSignature` reuses the same verifier
against the group key, with no delegate path.

An EIP-1271 call is capped at 100,000 gas (`NitroUtils.EIP1271_GAS`). FROST
verification costs about 4,200 gas, plus the cost of point decompression.
The cap holds.
