// Package block_party is the on-chain page of the Block Party listing in the
// Memba App Store. The game runs in Memba; this realm holds no state.
package block_party

// Render returns the same page for every path.
func Render(_ string) string {
	return `# Block Party

*Daily chain-seeded 2048 puzzle*

A daily 2048 merge game seeded from a Gno block — everyone plays the same board. Play with no wallet; connect to save your streak and climb the leaderboard.

## How to play

- Arrow keys, or a swipe on touch screens, slide every tile.
- Two equal tiles merge into one worth their sum.
- A daily run ends when its moves run out (30, or 24 on Rush days) or when no tile can move; practice runs are unlimited.

## Scores

The Memba backend replays every move of a daily run before it enters the leaderboard, so scores are verified off-chain. This realm stores no scores.

[Play Block Party in Memba](https://memba.samourai.app/mainnet/game)
`
}
