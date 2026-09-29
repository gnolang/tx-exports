# `gno.land/r/moul/gno4`

**Connect Four with the chain as the referee.** Open a table, wait for an opponent, and
play. Every move is a transaction; every board is a page.

The rules are not here. They live in [`p/moul/gno4`](/p/moul/gno4/v0), which has never
heard of a chain. This realm owns the three things that package cannot decide:

| | |
|---|---|
| **who** | a move is refused unless the caller holds the seat whose turn it is |
| **when** | an open table cannot be played, a finished one cannot be resumed |
| **what everyone sees** | `Render`, which is the product and not a debug view |

**A game is stored as its move list and nothing else.** Seven bytes for the game above,
42 for the longest possible one. The board is replayed on read. That keeps storage
minimal and bounded, keeps one canonical representation, and means an engine change never
needs a state migration, because what is on chain is the input rather than a derived
structure some future version might read differently.

**Nothing here is a wager.** A table holds no coins, so there is no escrow, no payout, and
no abandoned-table timeout to get wrong. Money is a second design and not a flag on this
one.

**No page hardcodes this realm's path.** The same source is deployed twice, here and at
`/preview`, and every link is built from the package path the code is actually running
under. A hardcoded link would send every click on the preview back to production and look
like it was working.

Pages: the lobby at the root, `:g/<id>` for a table, `:u/<address>` for a player,
`:about` for what the repository is exploring. All of them are readable with no wallet and
no JavaScript.

Source, the checklist it is written against, and the web front-end:
[github.com/moul/gno4](https://github.com/moul/gno4).
