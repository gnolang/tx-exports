// Package flood is Ribbonfight's hard house bot. For each free move it
// measures how much room it keeps with a flood fill, breaks ties by hugging
// walls (fewer free neighbours wastes less space), and avoids head-on
// collisions unless it is cornered.
//
// To stay cheap in gas it first counts room with a small budget and only
// runs the deep count when two or more moves look equally roomy and one of
// them passes through a narrow cell, which is when sealing a pocket is a
// real risk.
package flood

import "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfrh1/rules/v1"

const (
	Shallow = 20
	Deep    = 150
)

// Move is the bot.
func Move(v rules.View) rules.Dir {
	me, opp, h := v.Me(), v.Opp(), v.Heading()
	var cand [4]rules.Dir
	var room, nbr [4]int
	n := 0
	capped, narrow := 0, false
	for i := 0; i < 4; i++ {
		d := (h + rules.Dir(i)) % 4
		p := me.Step(d)
		if !v.Free(p.X, p.Y) {
			continue
		}
		cand[n] = d
		room[n] = v.Reach(p.X, p.Y, Shallow)
		nbr[n] = v.FreeDirs(p.X, p.Y)
		if room[n] == Shallow {
			capped++
			if nbr[n] <= 2 {
				narrow = true
			}
		}
		n++
	}
	if n == 0 {
		return h
	}
	if capped >= 2 && narrow {
		for k := 0; k < n; k++ {
			if room[k] == Shallow {
				p := me.Step(cand[k])
				room[k] = v.Reach(p.X, p.Y, Deep)
			}
		}
	}
	best, bestScore := cand[0], -100000
	for k := 0; k < n; k++ {
		p := me.Step(cand[k])
		score := 16*room[k] - 2*nbr[k]
		if abs(p.X-opp.X)+abs(p.Y-opp.Y) == 1 {
			score -= 400
		}
		if cand[k] == h {
			score++
		}
		if score > bestScore {
			best, bestScore = cand[k], score
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
