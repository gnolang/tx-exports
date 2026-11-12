package holdem

// MaxPlayers is the largest number of players in one hand.
const MaxPlayers = 6

// Pot is one main or side pot.
type Pot struct {
	Amount   int64
	Eligible []int // player indices that can win this pot
}

// BuildPots splits contributions into a main pot and side pots. Folded
// players' chips go into the pots but they are never eligible. Chips above the
// largest contribution of any live player form a last pot that only the live
// players with that contribution can win (an uncalled bet returns to its
// owner this way).
func BuildPots(contrib []int64, folded []bool) []Pot {
	levels := []int64{}
	for i, c := range contrib {
		if folded[i] {
			continue
		}
		pos := len(levels)
		dup := false
		for k, l := range levels {
			if l == c {
				dup = true
				break
			}
			if l > c {
				pos = k
				break
			}
		}
		if dup {
			continue
		}
		levels = append(levels, 0)
		copy(levels[pos+1:], levels[pos:])
		levels[pos] = c
	}
	if len(levels) == 0 {
		panic("no live players")
	}
	pots := []Pot{}
	prev := int64(0)
	for li, lvl := range levels {
		last := li == len(levels)-1
		amount := int64(0)
		for _, c := range contrib {
			hi := c
			if !last && hi > lvl {
				hi = lvl
			}
			if hi > prev {
				amount += hi - prev
			}
		}
		eligible := []int{}
		for i, c := range contrib {
			if !folded[i] && c >= lvl {
				eligible = append(eligible, i)
			}
		}
		prev = lvl
		if amount == 0 {
			continue
		}
		if n := len(pots); n > 0 && sameInts(pots[n-1].Eligible, eligible) {
			pots[n-1].Amount += amount
			continue
		}
		pots = append(pots, Pot{Amount: amount, Eligible: eligible})
	}
	return pots
}

func sameInts(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// Distribute awards each pot to its best eligible scores, splitting ties
// equally. The odd chips of a split pot all go to the winner that comes first
// in oddOrder (player indices clockwise from the button). It returns the
// amount won per player; the sum always equals the sum of the pots. It panics
// for more than MaxPlayers scores.
func Distribute(pots []Pot, scores []int, oddOrder []int) []int64 {
	if len(scores) > MaxPlayers {
		panic("too many players")
	}
	var buf [MaxPlayers]int64
	won := buf[:len(scores):len(scores)]
	for _, p := range pots {
		best := -1
		for _, i := range p.Eligible {
			if scores[i] > best {
				best = scores[i]
			}
		}
		winners := []int{}
		for _, i := range p.Eligible {
			if scores[i] == best {
				winners = append(winners, i)
			}
		}
		share := p.Amount / int64(len(winners))
		for _, i := range winners {
			won[i] += share
		}
		rem := p.Amount - share*int64(len(winners))
		if rem > 0 {
			for _, i := range oddOrder {
				if scores[i] == best && contains(winners, i) {
					won[i] += rem
					rem = 0
					break
				}
			}
			if rem > 0 {
				panic("odd chip order misses a winner")
			}
		}
	}
	return won
}

func contains(xs []int, x int) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}

// OddChipOrder returns player indices clockwise starting left of the button,
// for hand players indexed from the small blind (heads-up: index 0 is the
// button). It panics unless 0 <= n <= MaxPlayers.
func OddChipOrder(n int) []int {
	if n < 0 || n > MaxPlayers {
		panic("bad player count")
	}
	var buf [MaxPlayers]int
	out := buf[:n:n]
	if n == 2 {
		out[0], out[1] = 1, 0
		return out
	}
	for i := range out {
		out[i] = i
	}
	return out
}
