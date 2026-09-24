// Package space_invaders is the on-chain page of the Space Invaders listing in
// the Memba App Store. The game runs in Memba; this realm holds no state.
package space_invaders

// Render returns the same page for every path.
func Render(_ string) string {
	return `# Space Invaders

*Classic arcade shooter*

Defend the baseline across escalating waves in a browser-native Space Invaders. Play instantly with no wallet — keyboard on desktop, full touch controls on mobile. Deterministic engine, local high score.

## How to play

- Left and right arrows, or A and D, move.
- Space or W fires. P or Esc pauses. Enter launches a run.
- On touch screens, drag on the left half to steer and tap the right half to fire.

## Scores

Your high score stays in your browser. When certification is on, the Memba backend replays a daily run before it can reach the on-chain arcade board. This realm stores no scores.

[Play Space Invaders in Memba](https://memba.samourai.app/mainnet/game/space-invaders)
`
}
