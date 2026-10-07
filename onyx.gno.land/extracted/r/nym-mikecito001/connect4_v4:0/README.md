# `connect4` - staked Connect 4

## Context

We want a real-money Connect 4 on gno.land: equal ugnot stakes, winner takes
the pot minus a small house fee, fast turns, a lobby of offers open for the
next N minutes, and a guarantee both players are present once a game starts.

Two platform facts shape the design:

- `time.Now()` is the block timestamp. It is deterministic and only advances
  per block; nothing executes on its own, so deadlines are enforced lazily by
  whichever transaction checks them.
- Presence cannot be observed on-chain. The only proof a player is there is a
  transaction they signed.

## Decision

- **Lobby of offers.** `Offer` escrows the creator's stake with an expiry
  (1-60 min) and an optional reserved opponent. `Accept` must send exactly the
  same stake. Both use `cur.Previous().IsUserCall()` + `unsafe.OriginSend()`.
- **Presence via the move clock.** Each move has 90s of block time. `Accept`
  proves the acceptor is present, `Reveal` the creator, and the first move
  the first mover. If
  the clock runs out with zero moves the game is void and both stakes are
  refunded (the absent player may be the creator who posted long ago); after
  at least one move, the player on turn forfeits. Anyone can call
  `ClaimTimeout`, so bystanders can settle stuck games. A late `Play` panics
  rather than settling, keeping one settlement path.
- **First mover by two-sided commit-reveal.** `Offer` takes `commitment`,
  the lowercase hex `sha256(passphrase)`; `Accept` takes `seedCommitment`,
  the same for the acceptor's seed. The game then waits (`Turn = 0`, `Play`
  rejected) for the creator's `Reveal(id, passphrase)` within 90s of Accept,
  then the acceptor's `RevealSeed(id, seed)` within 90s of that. The first
  mover is the low bit of `sha256(passphrase|seed|id|creator|acceptor)`.
  When a player commits, the other side's secret is still hidden, so neither
  can grind for an outcome; once revealed, a secret can't change. The only
  way out is not revealing, which forfeits: `ClaimTimeout` pays the other
  player as a win. A pending Accept shows only a hash, so a creator watching
  the mempool learns nothing it could cancel on.
- **Commitments are one-use per address.** A revealed secret is public, so
  reusing it would let the other side compute the draw. Reuse is refused per
  address (creator or acceptor), never globally, so nobody can block another
  player's offer by posting its commitment first.
- **Fee** is a flat 0.1 GNOT (100,000 ugnot) per decisive game (one with a
  winner), adjustable by the owner up to 0.5 GNOT (half the minimum stake)
  and snapshotted per game at `Offer`, so a live game's terms never change.
  `Offer` takes the highest fee the creator accepts (`maxFee`) and refuses a
  higher one, so the owner can't raise it while an offer is in flight; the
  cap bounds it for everyone. `ActiveJSON` gives the current fee, and the
  gnoweb offer link passes it. Draws and void games pay no fee. The lobby shows each offer's
  own fee. The owner (`p/nt/ownable/v0`) can `SetFee` and `WithdrawFees`
  (collected fees only, never stakes); it is whoever deploys the realm
  (`init` with an `IsUserCall()` previous), so the deploying multisig owns it
  with no address baked into the code. Ownership moves in two steps,
  `TransferOwnership(newOwner)` then `AcceptOwnership()` by that address, so
  a mistyped spelling can never strand ownership and fees.
- **Address arguments must be canonical.** The chain accepts four texts for
  one address (bech32 or bech32m, lower or upper case), but a caller's
  address is always lower-case bech32. An opponent or a new owner in another
  spelling could never match its caller, so `Offer` and `TransferOwnership`
  refuse it (`address.gno`, the check of `p/samcrew/launchpad/meta/v1`,
  copied so the realm doesn't depend on that package).
- **Stale moves.** `Play(id, column, move)` takes the move count the player
  saw and refuses any other. A client that re-sends a move whose outcome it
  could not see (a dropped response) cannot have it land on a later turn.
- **Session keys.** Calls signed by a tm2 account session key (gno #5307;
  `runtime.GetSessionInfo`) may `Play`, `Reveal`, `RevealSeed`,
  `ClaimTimeout` and `Cancel` only. Session allow-paths are per realm, not per function, and a
  session's spend limit counts gas and sent coins but not what a call
  forfeits: a stolen session key could otherwise `Resign` every live game.
  `Offer`/`Accept` (stakes) and the owner functions need the account's own
  key too.
- **Cancel.** The creator may cancel an open offer at any time; anyone may
  once it has expired, so stale offers can be cleared. The refund always goes
  to the creator.
- **Non-payable calls reject coins.** Every function other than `Offer` and
  `Accept` panics if coins are sent, so nothing gets stuck in the realm.
- **Payouts are pushed** with a RealmSend banker inside the settling tx, after
  state is updated. Native coin sends run no callee code.
- **Leaderboards** (wins, net ugnot won: the opponent's stake minus the
  fee) update only on Won/Draw, so void
  or cancelled games cannot farm stats. The two top-10 boards are kept at
  settlement (`bump`), so Render never walks every player's stats.
- An `active` tree holds only Open/Playing games so the lobby render cost does
  not grow with history, and the lobby lists at most 50 of them; clients page
  through `ActiveJSON`.

## Alternatives considered

- First mover from a hash computed in `Accept` (block height, time, ids).
  Rejected: a tx can carry several messages and is atomic, so an acceptor can
  send `[Accept, Play]` and let the whole tx revert whenever the pick goes
  against them, then retry next block.
- Creator-only commit-reveal, with the `Accept` block height mixed in (the
  first hardened version). Rejected in review: a short private offer can only
  be accepted at about 12-18 heights, so a creator can grind one passphrase
  that moves first at all of them (about 2^18 tries).
- An acceptor seed sent in clear with `Accept`. Rejected: the creator sees it
  in the mempool and could cancel, or accept with another account, before
  the Accept lands whenever the draw goes against it.
- The creator picking the first mover in the offer, or a two-game match with
  each side moving first once: no randomness at all, but a different game.

- Matchmaking queue by stake tier: faster pairing, but no browsable lobby and
  it pairs people with idle players.
- Explicit "ready" handshake after accept: an extra tx per game that the first
  move already provides.
- Forfeit on first-move timeout: punishes an acceptor's opponent who simply
  posted an offer and left before it was taken; void is fairer.
- Chess-style time banks / per-game timeouts: more state and UI for little
  gain at this stage.

## Consequences

- Clocks are only as precise as block production: a move can land a few
  seconds past 90s if no block was produced in between. Symmetric for both
  players.
- A weak secret can be brute-forced offline from its public commitment,
  letting the other side steer the draw. This cannot be enforced on-chain;
  the pages ask for `openssl rand -hex 32`, and Memba generates 32 random
  bytes for both.
- Each game needs two extra txs before the first move, `Reveal` and
  `RevealSeed`, each within 90s; both players must stay online until then.
- Self-play with an alt account inflates wins but costs the fee.
- A stolen session key can still play bad moves, one per turn, in the
  owner's live games. That is inherent to signing moves without the wallet;
  the client keeps sessions short and bounded.

## Security review (before mainnet)

An audit against `docs/resources/gno-ai-contract-review.md`, the payment
guidance in `effective-gno.md` and `misc/audit-pattern-harness`, then two
reviews of this repository's PR, led to the two-sided draw, one-use
commitments, the stale-move check, session-key refusals, the fee cap,
two-step ownership, settlement-time leaderboards, the capped lobby and the
deployer-owner above. Confirmed sound:
the `IsUserCall()` + `OriginSend()` payment pair, no exported pointers or
callbacks, Render writing only validated addresses and formatted numbers,
fee < stake per game, exact refunds, and `Play` (until the deadline) and
`ClaimTimeout` (after it) never overlapping. The harness's `current_guard`
hits are the `cur.IsCurrent()` guard that AGENTS.md says not to write in
crossing functions.

## Read accessors

`GameJSON(id)` (with `seedCommitment` and `revealed`), `ActiveJSON(offset, limit)` and `LeadersJSON()` (the two top-10 boards) return hand-built JSON for
clients (Memba's Arcade) that read over `vm/qeval` instead of scraping
`Render`. Each response carries `now`, the block time, so clients count the
90s clock in chain time. The board is a 42-char column-major string. Strings
go through `strconv.Quote` although every stored string is validated on
write. The accessors never call `statsOf`, which writes on a miss.
