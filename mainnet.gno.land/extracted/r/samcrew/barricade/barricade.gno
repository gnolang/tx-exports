// Package barricade is the on-chain page of the BARRICADE listing in the Memba
// App Store. The game runs in Memba; this realm holds no state.
package barricade

// Render returns the same page for every path.
func Render(_ string) string {
	return `# BARRICADE

*Hold the Paris barricade against the machines*

A browser-native defence game in a French civic setting: hold the cobblestone barricade as waves of machines advance down three lanes. Play instantly with no wallet — a wide battlefield on desktop, a portrait front line on phones.

## How to play

- Left and right arrows, 1, 2 and 3, or a tap on a lane change lanes; you fire automatically.
- S shoves the nearest machine in your lane, R rallies, P pauses.
- M or the Molotov button aims a molotov: arrows choose lane and range and Enter throws, or tap the target.
- Between waves, spend scrap on repairs, turrets or the crowd.

## Scores

Everyone gets the same daily seed; practice runs do not count. When certification is on, the Memba backend replays a daily run before it can reach the on-chain arcade board. This realm stores no scores.

[Play BARRICADE in Memba](https://memba.samourai.app/mainnet/game/barricade)
`
}
