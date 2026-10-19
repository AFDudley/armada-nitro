# Nitro and ForceMove specification clauses

The testable clauses of the specification sources in `README.md` (S3, S4; S1, S2 and S5 as background), each with
its source section, the code site in `src/nitro/` or `lib/exit-format/`, and the armada-nitro local edits that touch it.

**Status.** Research output, not yet tested. A research agent derived the clauses on 2026-10-18 from the sources in
`sources/`. On 2026-10-19 every file:line citation was checked to lie inside its file at `9c8898d` (47 citations, 0
out of range; `src/nitro/` is unchanged since `f720847`), and clauses 5, 25, 31 and silences Sil4 and Sil6 were read
against the code and hold. Task E17 turns each clause into a test: a mutation proves a clause the code meets, and a
red commit comes first for a clause it does not meet.

Counts: 31 clauses (A 1-6, B 7-10, C 11-18, D 19-22, E 23-29, F 30-31), 8 differences (D1-D8), 7 silences
(Sil1-Sil7). A statement marked `[INFERENCE]` is a deduction, not a quote from a source.

## 0. Code under study

`src/nitro/` holds the vendored go-nitro `nitro-protocol` contracts.
The README pins the source to cerc-io/go-nitro `435eb2b` (v0.1.7).
See `README.md:20`.
`lib/exit-format` is statechannels/exit-format `43450d8` (npm 0.2.0).

The first vendor commit was unmodified. The later commits are the armada-nitro
local edits. `git log -- src/nitro` shows them:

| Commit | Scope under `src/nitro` |
|---|---|
| `8edacc1` | Vendor unmodified. 16 files, 1976 insertions. |
| `5ff5eee` | Accept EIP-1271 participants. Remove the L2 bridge stub. |
| `25f40ba` | Fix the guarantee check in `MultiAssetHolder.transfer`. |
| `592a7f3` | Credit a deposit by measured balance. Revert on short transfer. |
| `04b8431` | Split `deposit` into `_doDeposit` for the adjudicator asset-list override. |
| `32ad5e5` | Per-channel `holdingsLock` reentrancy guard. |
| `8570389` | Pay out ERC20 with SafeERC20. |

The local edits carry `armada-nitro:` comments in the code. Example:
`src/nitro/ForceMove.sol:178-179` and `src/nitro/libraries/NitroUtils.sol:89-99`.

## 1. Sources

See `README.md`.

## 2. How the protocol changed from the papers to the code

1. **Turn-taking became application-defined support.**
   S1 fixes `mover = participants[turnNum % n]` and a per-type `validTransition`
   (S1 section 3.1.3, PDF line 373; section 3.2). The code instead delegates all
   execution rules to an app contract `stateIsSupported(fixedPart, proof,
   candidate)` (S4 `0020`; `src/nitro/interfaces/IForceMoveApp.sol:11-21`;
   `src/nitro/ForceMove.sol:206-217`). Turn-taking survives only as one optional
   library, `StrictTurnTaking` (`src/nitro/libraries/signature-logic/
   StrictTurnTaking.sol`), used by the `HashLockedSwap` example
   (`src/nitro/examples/HashLockedSwap.sol:47`). The default ledger app uses
   **consensus**, not turn-taking (`src/nitro/ConsensusApp.sol:18-25`).

2. **The dispute operations were renamed and reshaped.**
   S1 uses `forceMove`, `respondWithMove`, `refute`, `conclude`. The code uses
   `challenge`, `checkpoint`, `conclude` over support proofs
   (`src/nitro/ForceMove.sol:39,90,127`; S4 `0070`). SATP keeps `challenge` and
   `conclude` (S3 section 2.3).

3. **`claim` became `reclaim`; guarantees changed shape.**
   S2 defines `transfer` and `claim`, and guarantees that reprioritise a target
   through a list of addresses (S2 section 6.1, PDF lines 566, 588). The code has
   `transfer`, `transferAllAssets`, and `reclaim`
   (`src/nitro/MultiAssetHolder.sol:95,259`; `NitroAdjudicator.sol:41`). A
   guarantee now stores exactly two destinations `{left,right}`
   (`src/nitro/MultiAssetHolder.sol:538-541`; S4 `0030`; S3 section 2.4). This is
   the SATP shape, not the Nitro-paper shape.

4. **The outcome became the L2 exit format.**
   S2 models an outcome as a list of address/amount pairs (S2 section 5.1). The
   code uses `ExitFormat.SingleAssetExit[]`, with per-asset metadata and an
   `AllocationType` enum (`lib/exit-format/contracts/ExitFormat.sol:26-75`; S4
   `0030`). This supports many assets per channel and ERC20/721/1155.

5. **The exit format is explicit and multi-asset.**
   S1/S2 treat a single asset (coins). The code loops over assets in
   `transferAllAssets` (`src/nitro/NitroAdjudicator.sol:67-102`) and supports
   native, ERC20, ERC721, ERC1155, and Qualified assets
   (`lib/exit-format/contracts/ExitFormat.sol:51,151-237`).

## 3. Testable clauses

Each clause gives the source and section, then the code location in `src/nitro/`
(or `lib/exit-format/`), then whether an armada-nitro local edit changes it.
"absent" means the code has no such location. S4 page ids are the docs tutorial
numbers. File:line is from the read of the pinned working tree this run.

### A. State and identity

1. **FixedPart = {participants, channelNonce, appDefinition, challengeDuration}.**
   Source: S4 `0010` (States); S3 section 2.1 `ChannelConsts`.
   Code: `src/nitro/interfaces/INitroTypes.sol:13-18`.
   Local edit: none.

2. **VariablePart = {outcome, appData, turnNum, isFinal}.**
   Source: S4 `0010`; S3 section 2.1 `ChannelVars`.
   Code: `src/nitro/interfaces/INitroTypes.sol:20-25`.
   Local edit: none.

3. **channelId = keccak256(abi.encode(participants, channelNonce, appDefinition,
   challengeDuration)).**
   Source: S4 `0010` (Channel IDs).
   Code: `src/nitro/libraries/NitroUtils.sol:177-188`.
   Local edit: none.

4. **stateHash = keccak256(abi.encode(channelId, appData, outcome, turnNum,
   isFinal)).**
   Source: S4 `0010` (State commitments).
   Code: `src/nitro/libraries/NitroUtils.sol:204-227`.
   Local edit: none.

5. **A participant list must hold 2..255 entries.**
   Source: S4 `0010` (Participants warning); S1 note `n <= 255` is implicit.
   Code: enforced only in `StrictTurnTaking._requireValidInput`
   (`src/nitro/libraries/signature-logic/StrictTurnTaking.sol:88-96`), which the
   core does not call. The adjudicator itself does not check the bound. See
   section 5, silence item.
   Local edit: none.

6. **A signature is {v, r, s} over the EIP-191 prefixed state hash.**
   Source: S4 `0010` (State commitments, Signature struct).
   Code: struct `src/nitro/interfaces/INitroTypes.sol:7-11`; prefix and recover
   `src/nitro/libraries/NitroUtils.sol:71-87`.
   Local edit: none for the struct. The authorisation path adds EIP-1271; see
   clause 8.

### B. Execution rules

7. **The app contract decides support through `stateIsSupported(fixedPart,
   proof, candidate)`. Higher turn numbers take precedence. The app returns
   (bool, reason).**
   Source: S4 `0020` (Application rules); S3 section 2.2 `latestSupportedState`.
   Code: interface `src/nitro/interfaces/IForceMoveApp.sol:11-21`; adjudicator
   delegate `src/nitro/NitroAdjudicator.sol:121-132`; internal call
   `src/nitro/ForceMove.sol:206-217`.
   Local edit: none.

8. **A signature counts for participant i if i signed as an EOA, or, when i is a
   contract, if i accepts the signature through EIP-1271.**
   Source: no upstream spec clause. This is an armada-nitro addition; the README
   states it (`README.md`, "EIP-1271 participants").
   Code: `src/nitro/libraries/NitroUtils.sol:101-126`; used by
   `src/nitro/ForceMove.sol:247-269` and `:184-197`.
   Local edit: **yes**. Added by `5ff5eee`. The EIP-1271 staticcall is gas-capped
   at 100000 (`NitroUtils.sol:62`). This has no counterpart in S1-S4, which all
   assume ECDSA participants. See section 4.

9. **The ConsensusApp supports a state only when every participant signed it, and
   the proof is empty.**
   Source: S4 `0020` (ConsensusApp); S3 section 2.2 consensus app.
   Code: `src/nitro/ConsensusApp.sol:18-25`;
   `src/nitro/libraries/signature-logic/Consensus.sol:18-28`.
   Local edit: none.

10. **Strict turn-taking: each proof state is signed only by its mover
    (turnNum % n), turn numbers increment by one, and |participants| = |proof|+1.**
    Source: S1 section 3 (mover rule, PDF line 373; validMove, PDF line 391).
    Code: `src/nitro/libraries/signature-logic/StrictTurnTaking.sol:15-96`.
    Local edit: none. The core adjudicator does not use this library; only the
    `HashLockedSwap` example uses it (`src/nitro/examples/HashLockedSwap.sol:47`).

### C. Dispute lifecycle

11. **A channel is Open, Challenge, or Finalized, derived from `finalizesAt`:
    0 = Open, future = Challenge, past-or-now = Finalized.**
    Source: S4 `0040` (Channel modes, `_mode`); S3 section 2.3 `isOpen`.
    Code: `src/nitro/StatusManager.sol:17-30`.
    Local edit: none.

12. **`statusOf[channelId]` packs turnNumRecord (48 bits), finalizesAt (48 bits),
    and a 160-bit fingerprint of keccak256(stateHash, outcomeHash).**
    Source: S4 `0040` (Adjudicator storage, fingerprint).
    Code: `src/nitro/StatusManager.sol:37-93`.
    Local edit: none.

13. **`challenge(fixedPart, proof, candidate, challengerSig)` registers a
    challenge, sets finalizesAt = now + challengeDuration, and stores the
    supported state.**
    Source: S4 `0070` (Call challenge); S3 section 2.3 Listing 1.
    Code: `src/nitro/ForceMove.sol:39-81`.
    Local edit: none to the flow. The challenger check accepts EIP-1271 (clause
    8), `src/nitro/ForceMove.sol:184-197`.

14. **`challengerSig` signs keccak256(abi.encode(supportedStateHash,
    'forceMove')), and the signer must be a participant.**
    Source: S4 `0070` (challenge Note).
    Code: `src/nitro/ForceMove.sol:184-197`.
    Local edit: EIP-1271 acceptance only (clause 8).

15. **`challenge` turn-number rule: when Open, the candidate turn must not
    decrease; when already in Challenge, it must strictly increase.**
    Source: S4 `0040` ("higher turn numbers take precedence"); S3 section 2.3
    `version >= status.version`.
    Code: `src/nitro/ForceMove.sol:48-55`, `:277-294`.
    Local edit: none.

16. **`checkpoint(fixedPart, proof, candidate)` stores a strictly higher
    turnNumRecord and leaves the channel Open (clears a challenge).**
    Source: S4 `0070` (Call checkpoint); S4 `0040` state machine
    (Challenge -> Open: checkpoint).
    Code: `src/nitro/ForceMove.sol:90-119`.
    Local edit: none.

17. **`conclude(fixedPart, candidate)` finalises instantly when the candidate is
    final and all participants signed it. It sets finalizesAt = now and
    turnNumRecord = 0.**
    Source: S4 `0070` (On chain conclude); S3 section 2.3 (Conclude).
    Code: `src/nitro/ForceMove.sol:127-170`; unanimity check `:153-157`; the
    turnNumRecord reset to 0 `:160-166` matches S4 `0040` ("set to 0 when ...
    concluded").
    Local edit: none.

18. **A challenge not cleared before `finalizesAt` finalises by timeout.**
    Source: S4 `0040` (Challenge -> Finalized': timeout); S1 section 4.1.
    Code: passive, through `_mode` (`src/nitro/StatusManager.sol:25-26`). No
    separate function. [INFERENCE] The timeout is implicit in the timestamp
    comparison; no call is needed.
    Local edit: none.

### D. Outcomes and asset management

19. **An Outcome is `SingleAssetExit[]`. Each has an asset, assetMetadata, and an
    ordered `Allocation[]`.**
    Source: S4 `0030` (Outcomes); S3 section 2.4.
    Code: `lib/exit-format/contracts/ExitFormat.sol:26-40`.
    Local edit: none.

20. **An Allocation is {destination, amount, allocationType, metadata}.
    allocationType 0 = simple, 2 = guarantee.**
    Source: S4 `0030` (Allocations, Guarantees).
    Code: struct `lib/exit-format/contracts/ExitFormat.sol:70-75`; enum
    `AllocationType {simple, withdrawHelper, guarantee}` `:63`.
    Local edit: none. (armada-nitro adds a `SHIELD` type at the adjudicator
    layer, not in `src/nitro` or exit-format; see `README.md`.)

21. **A guarantee's metadata encodes `{bytes32 left; bytes32 right}`, two channel
    participants.**
    Source: S4 `0030` (Guarantees struct); S3 section 2.4 `G(x,[A,B])`.
    Code: `src/nitro/MultiAssetHolder.sol:538-545`.
    Local edit: none.

22. **A destination is external when its top 96 bits are zero (a 20-byte address
    left-padded). Otherwise it is a channel id.**
    Source: S4 `0030` (Destinations).
    Code: `src/nitro/MultiAssetHolder.sol:471-473`;
    `lib/exit-format/contracts/ExitFormat.sol:270-272`.
    Local edit: none.

### E. Funding and defunding operations

23. **`deposit(asset, channelId, expectedHeld, amount)` credits holdings only
    when `held == expectedHeld`, and refuses an external destination.**
    Source: S4 `0060` (on-chain deposit); S1 section 6.2; S2 section 3.1 deposit.
    Code: `src/nitro/MultiAssetHolder.sol:43-84`; expectedHeld check `:62`;
    external-destination check `:59`.
    Local edit: **yes**. `592a7f3` credits by measured balance and reverts on a
    short transfer (`:75-79`). `04b8431` split the body into `_doDeposit` for the
    adjudicator override (`:52-58`). `32ad5e5` added the `holdingsLock` guard
    (`:64-66`). None change the deposit contract in S4; they harden it.

24. **`transfer(assetIndex, fromChannelId, outcomeBytes, stateHash, indices)`
    pays simple allocations in priority order up to the held amount, and updates
    the stored outcome fingerprint. An empty `indices` means "all".**
    Source: S4 `0080` (on-chain transfer); S2 section 5.1 (priority order,
    afford), section 6 (transfer).
    Code: `src/nitro/MultiAssetHolder.sol:95-135`; priority math
    `compute_transfer_effects_and_interactions` `:161-217`; the `min(amount,
    surplus)` afford rule `:193`.
    Local edit: `32ad5e5` added the `holdingsLock` guard (`:108-110,134`).

25. **`transfer` must refuse a guarantee allocation.**
    Source: S4 `0030` ("When allocationType is guarantee, funds cannot be
    transferred in the usual way"); S3 section 2.4 (guarantees use reclaim).
    Code: `src/nitro/MultiAssetHolder.sol:195-196` (`revert 'cannot transfer a
    guarantee'`).
    Local edit: **yes**. `25f40ba` fixed this check. The README says this fix was
    also released upstream as cerc-io/go-nitro v0.1.8. [INFERENCE] The pin
    `435eb2b` (v0.1.7) therefore shipped the bug; armada-nitro backported the
    fix.

26. **`transferAllAssets(channelId, outcome, stateHash)` pays every asset of a
    finalised channel, deletes the status when only zeros remain, else re-stores
    the updated fingerprint.**
    Source: S4 `0080` (concludeAndTransferAllAssets convenience; transfer for
    all assets).
    Code: `src/nitro/NitroAdjudicator.sol:41-112`; status delete `:104-108`.
    Local edit: `32ad5e5` added the `holdingsLock` guard (`:46-51`).

27. **`concludeAndTransferAllAssets(fixedPart, candidate)` concludes then pays
    out every asset in one call.**
    Source: S4 `0080` (convenience method).
    Code: `src/nitro/NitroAdjudicator.sol:21-32`.
    Local edit: `32ad5e5` added the `holdingsLock` guard (`:27-31`).

28. **`reclaim(ReclaimArgs)` moves a guaranteed target channel's funds back into
    the guaranteeing ledger channel, removes the guarantee, and credits `left`
    and `right` by the target's first two allocation amounts. Both channels must
    be finalised. The total reclaimed must equal the guarantee amount.**
    Source: S3 section 2.4 Listing 2 (Reclaim); S4 `0080` (Reclaim and transfer
    out).
    Code: `src/nitro/MultiAssetHolder.sol:259-428`; checks `:291-345`;
    credit math `compute_reclaim_effects` `:350-399`; total check `:396`.
    Local edit: `32ad5e5` added the `holdingsLock` guard (`:265-267,285`).

29. **An external destination is paid; an internal destination is credited to its
    channel holdings.**
    Source: S2 section 3.1 (deposit/withdraw semantics); S4 `0080` (transfer
    moves funds to an external destination or another channel).
    Code: `src/nitro/MultiAssetHolder.sol:435-448`.
    Local edit: **yes**. `8570389` pays ERC20 with SafeERC20
    (`_transferAsset` `:456-463`). This hardens, not changes, the spec behaviour.

### F. Exit format execution

30. **`executeSingleAssetExit` pays native by low-level call, ERC20 by transfer,
    ERC721/1155 by safeTransferFrom, and skips a foreign (Qualified, wrong chain
    or holder) asset.**
    Source: the exit-format repo (S4 `0030` links it). exit-format has no prose
    spec beyond the contract comments.
    Code: `lib/exit-format/contracts/ExitFormat.sol:151-263`.
    Note: the adjudicator does **not** call this library function. It uses its
    own `_executeSingleAssetExit` (`src/nitro/MultiAssetHolder.sol:435-448`),
    which handles only native and ERC20. See section 5.
    Local edit: the exit-format library is unmodified. The adjudicator's own copy
    was edited (clause 29).

31. **A `withdrawHelper` allocation calls an external helper after payout.**
    Source: exit-format contract comments (`ExitFormat.sol:77-84,226-235`).
    Code: present in `lib/exit-format` only. The adjudicator's
    `_executeSingleAssetExit` (`src/nitro/MultiAssetHolder.sol:435-448`) ignores
    `allocationType`, so a `withdrawHelper` is paid as a plain transfer and the
    helper is never called. See section 5.
    Local edit: none to exit-format. [INFERENCE] The behaviour gap exists because
    the adjudicator re-implements payout instead of calling the library.

---

## 4. Differences: recent spec versus code

D1. **EIP-1271 participants (code adds, spec silent).**
   S1-S4 all assume ECDSA participants. The code accepts a contract participant
   through EIP-1271, with a 100000-gas cap on the staticcall
   (`src/nitro/libraries/NitroUtils.sol:101-126,62`). Added by `5ff5eee`.
   Clauses 6, 8, 14.

D2. **Per-channel reentrancy lock (code adds, spec silent).**
   `holdingsLock[channelId]` guards `deposit`, `transfer`, `transferAllAssets`,
   `concludeAndTransferAllAssets`, and `reclaim`
   (`src/nitro/MultiAssetHolder.sol:29,64-66,108-110,266-267`;
   `NitroAdjudicator.sol:27-31,46-51`). No spec mentions it. Added by `32ad5e5`.
   Clauses 23-28.

D3. **Deposit credited by measured balance (code hardens).**
   The code measures `balanceOf` before and after the ERC20 transfer and reverts
   on a mismatch (`src/nitro/MultiAssetHolder.sol:75-79`). S4 `0060` describes
   only the `expectedHeld` check. Added by `592a7f3`. [INFERENCE] This blocks
   fee-on-transfer and rebasing tokens from desyncing holdings.

D4. **ERC20 moves use SafeERC20 (code hardens).**
   `_transferAsset` and `_doDeposit` use `safeTransfer`/`safeTransferFrom`
   (`src/nitro/MultiAssetHolder.sol:76,461`). exit-format's own library uses raw
   `IERC20(asset).transfer` (`lib/exit-format/contracts/ExitFormat.sol:182`).
   The adjudicator path is the hardened one. Added by `8570389`.

D5. **Guarantee-transfer check was buggy at the pin.**
   The pin `435eb2b` (v0.1.7) carried the `transfer`-on-guarantee bug. The local
   commit `25f40ba` fixed it (`src/nitro/MultiAssetHolder.sol:195-196`). Clause
   25. [INFERENCE] Without the fix, a guarantee could be transferred as if it
   were a simple allocation.

D6. **The two papers disagree with the code on vocabulary and operations.**
   S1 (`forceMove`/`respond`/`refute`, state types, per-type `validTransition`)
   and S2 (`claim`, address-list guarantees, single-asset allocation list) do not
   match the code. The code matches S3 and S4. See section 2. The docs flag the
   papers as out of date.

D7. **Challenger authorisation digest.**
   S1 used a `forceMove` challenge signed by the mover. The code signs
   keccak256(abi.encode(supportedStateHash, 'forceMove')) and accepts any
   participant, EOA or EIP-1271 (`src/nitro/ForceMove.sol:184-197`). The literal
   string `'forceMove'` survives from the ForceMove era. Clause 14.

D8. **armada-nitro's note-native and SHIELD features sit above `src/nitro`.**
   `depositFromNote`, the `SHIELD` allocation type, and the hub asset list live
   in `src/ArmadaNitroAdjudicator.sol` and `src/HubCustodian.sol`, not in
   `src/nitro`. They extend the spec; they do not change the vendored clauses
   above. Source: `README.md`. [INFERENCE] They are out of scope for a
   clause-by-clause check of the vendored contracts, but a reader must know they
   override deposit and payout at the subclass layer.

---

## 5. Where the recent spec is silent

Sil1. **Participant-count bound.**
   S4 `0010` tells a client to check 2..255 participants, but names no on-chain
   check. The adjudicator enforces no bound; only `StrictTurnTaking` does
   (`src/nitro/libraries/signature-logic/StrictTurnTaking.sol:88-96`). A
   consensus channel with a huge participant list is not rejected on-chain.
   Clause 5.

Sil2. **Signature-set size and duplicate signers.**
   No spec states that `recoverVariablePart` stops at the first matching
   participant per signature, nor how duplicate or cross signatures are handled.
   The code assumes distinct participants and breaks on the first match
   (`src/nitro/ForceMove.sol:261-266`). The spec is silent on the exact bitmask
   rule.

Sil3. **EIP-1271 gas cap value.**
   No upstream spec mentions EIP-1271 at all, so the 100000-gas cap
   (`src/nitro/libraries/NitroUtils.sol:62`) has no spec basis. It is an
   armada-nitro design choice.

Sil4. **exit-format execution details.**
   The exit-format repo has no prose spec. The only "spec" is the contract
   comments. S4 `0030` links the repo but does not define `executeExit`,
   `withdrawHelper`, or Qualified-asset handling. The adjudicator does not call
   the library's `executeSingleAssetExit`; it uses its own native/ERC20-only
   `_executeSingleAssetExit` (`src/nitro/MultiAssetHolder.sol:435-448`). So
   `withdrawHelper` and ERC721/1155 exits are undefined on the adjudicator path.
   Clauses 30, 31.

Sil5. **Reentrancy and token-weirdness.**
   No upstream spec states a reentrancy model or a fee-on-transfer policy. The
   local edits D2, D3, D4 fill a gap the spec never addressed.

Sil6. **`reclaim` with more than two target allocations.**
   S3 Listing 2 and S4 `0080` describe reclaim for a two-party target. The code
   credits only `targetAllocations[0]` and `[1]`
   (`src/nitro/MultiAssetHolder.sol:381-387`). The spec does not define reclaim
   for a target with a different allocation count. [INFERENCE] A target with
   more than two allocations is outside both the spec and the code's reclaim
   math.

Sil7. **Multi-asset finalisation order.**
   S2/S3 reason about one asset. The code iterates assets in array order
   (`src/nitro/NitroAdjudicator.sol:67-102`). No recent spec states an ordering
   requirement across assets.
