# `gno.land/p/moul/gno4/v0`

**Connect Four, as rules and nothing else**: `New`, `Drop`, `Winner`, `Encode`, `Decode`, `SVG`.

```go
import "gno.land/p/moul/gno4/v0"

b, _ := gno4.Decode("1122334") // replay a whole game from 7 bytes
b.Winner()                     // -> gno4.Red
b.Line()                       // -> the four cells that won
b.Image("board")               // -> ![board](data:image/svg+xml;base64,...)
```

A realm that wants a game needs three different things: the rules, the authority to
decide who may move, and a way to show the result. Only the first is reusable, and only
the first can be tested without a chain. This package is the first, alone: it imports no
chain package, takes no address, reads no height, and has no idea a block exists.

**A game is its move list, deliberately.** `Encode` returns one digit per move and nothing
else; `Decode` replays them. The position, the winner and the winning line are all
derived, never stored, so there is exactly one representation and no second encoder that
can drift from it. A whole game is at most 42 bytes, which is small enough that a realm
stores the string and replays it rather than persisting a board.

Four behaviours worth knowing before you use it:

- **`Drop` is the only mutator.** Every illegal position this package could reach is
  refused in one place, which is why `Decode` can be trusted: it replays through `Drop`,
  so an encoding describing an impossible game (a column overflowing, a move after the
  win) is rejected rather than becoming a board no rule allows.
- **`At` returns `Empty` out of range instead of panicking.** Render loops walk past the
  edge on purpose, and a `Render` that panics is a realm page that is unreadable forever.
- **The winner is computed once, by the `Drop` that creates it.** A finished game is
  rendered far more often than it is played, and rescanning 69 lines per read is gas
  spent to learn something the board already knew.
- **`WinningMove` is one ply deep, on purpose.** It answers "can I win now" and "must I
  block now" for seven scans and no allocation. Real search belongs in the front-end,
  where nobody pays gas to think.

`SVG` draws the board with [`p/nt/svg`](/p/nt/svg/v0) and `Image` wraps it as a
`data:image/svg+xml;base64` markdown image, which is the one inline data URI gnoweb
allows. It is generated at render time, so it costs no storage and there is no asset to
go missing later.

Live demo: [r/moul/gno4](/r/moul/gno4).
