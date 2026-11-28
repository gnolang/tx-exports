// Package space is Ribbonfight's medium house bot. Among its free moves it
// picks the one with the most room nearby (a small flood fill), steers away
// from cells the opponent's head could also enter, and prefers to keep its
// heading on ties.
package space

import "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfrh1/rules/v1"

// Budget caps the room count per candidate move.
const Budget = 12

// Move is the bot.
func Move(v rules.View) rules.Dir {
	me, opp, h := v.Me(), v.Opp(), v.Heading()
	best, bestScore := h, -1000
	for i := 0; i < 4; i++ {
		d := (h + rules.Dir(i)) % 4
		n := me.Step(d)
		if !v.Free(n.X, n.Y) {
			continue
		}
		score := 4 * v.Reach(n.X, n.Y, Budget)
		if abs(n.X-opp.X)+abs(n.Y-opp.Y) == 1 {
			score -= 20
		}
		if d == h {
			score++
		}
		if score > bestScore {
			best, bestScore = d, score
		}
	}
	return best
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}
