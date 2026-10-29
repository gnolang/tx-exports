package arena

import "gno.land/p/g1sl6fyq6mrc3wydt8xluhxx4aqsudpp9vhv6g2a/gnomepit/engine"

const (
	startRating = 1000
	maxRating   = 0xFFFF // a ladder key holds the rating in 2 bytes
	playerK     = 32
	clanK       = 16
)

// expectedTable is the expected score, in thousandths, of a side whose opponent is rated
// 0, 25, …, 400 points above it: 1 / (1 + 10^(d / 400)), rounded.
var expectedTable = [17]int{500, 464, 429, 394, 360, 327, 297, 267, 240, 215, 192, 170, 151, 133, 118, 104, 91}

// expected is the expected score, in thousandths, of a side rated a against one rated b.
// The gap is capped at 400 points and rounded to the nearest 25.
func expected(a, b int) int {
	d := b - a
	if d < 0 {
		return 1000 - expected(b, a)
	}
	if d > 400 {
		d = 400
	}
	return expectedTable[(d+12)/25]
}

// eloChange is the change, rounded to the nearest point, of a side rated a that scored
// score thousandths (1000 a win, 500 a draw, 0 a loss) against one rated b.
func eloChange(a, b, score, k int) int {
	x := k * (score - expected(a, b))
	if x < 0 {
		return -((-x + 500) / 1000)
	}
	return (x + 500) / 1000
}

// applyChange gives a the change delta and b its negative, each kept within 0 to maxRating.
func applyChange(a, b, delta int) (int, int) {
	return clampRating(a + delta), clampRating(b - delta)
}

func clampRating(r int) int {
	if r < 0 {
		return 0
	}
	if r > maxRating {
		return maxRating
	}
	return r
}

// rate counts match m, which has just ended, in both players' standings and on the
// ladder, and in the clan records when two different clans met. A match its challenger
// accepted is not rated.
func rate(rules *engine.Ruleset, m record) {
	if m.challenger == m.acceptor {
		return
	}
	score := scoreOf(m.result)
	a, b := ratedStanding(rules, m.challenger), ratedStanding(rules, m.acceptor)
	a.rating, b.rating = applyChange(a.rating, b.rating, eloChange(a.rating, b.rating, score, playerK))
	a.count(score, m.clans[0])
	b.count(1000-score, m.clans[1])
	ladder, _ = ladder.Set(ladderKey(a.rating, m.challenger), nil)
	ladder, _ = ladder.Set(ladderKey(b.rating, m.acceptor), nil)
	saveStanding(m.challenger, a)
	saveStanding(m.acceptor, b)

	if m.clans[0] == m.clans[1] {
		return
	}
	c := decodeClans(clanRecords, len(rules.Clans))
	ca, cb := &c[m.clans[0]-1], &c[m.clans[1]-1]
	ca.rating, cb.rating = applyChange(ca.rating, cb.rating, eloChange(ca.rating, cb.rating, score, clanK))
	tally(score, &ca.wins, &ca.losses, &ca.draws)
	tally(1000-score, &cb.wins, &cb.losses, &cb.draws)
	clanRecords = encodeClans(c)
}

// ratedStanding returns a's standing, created at startRating for a first rated match, with
// a count for every clan of rules, and takes its key off the ladder until it is counted.
func ratedStanding(rules *engine.Ruleset, a address) *standing {
	st := loadStanding(a)
	if st == nil {
		st = &standing{rating: startRating}
	} else {
		ladder, _, _, _ = ladder.Remove(ladderKey(st.rating, a))
	}
	for len(st.perClan) < len(rules.Clans) {
		st.perClan = append(st.perClan, 0)
	}
	return st
}

// scoreOf is the challenger's score, in thousandths, in a match that ended with result.
func scoreOf(result string) int {
	switch result {
	case "a":
		return 1000
	case "b":
		return 0
	case "draw":
		return 500
	}
	panic("unknown result")
}

// count adds a match scored score thousandths and played as clan number clan.
func (s *standing) count(score, clan int) {
	tally(score, &s.wins, &s.losses, &s.draws)
	s.lastClan = clan
	s.perClan[clan-1]++
}

func tally(score int, wins, losses, draws *int) {
	switch score {
	case 1000:
		*wins++
	case 0:
		*losses++
	default:
		*draws++
	}
}

// mainClan is the clan number s has finished the most rated matches with, 0 for none. A
// tie goes to the last match's clan when it is one of the tied, else to ruleset order.
func (s standing) mainClan() int {
	best := 0
	for i, n := range s.perClan {
		if n > 0 && (best == 0 || n > s.perClan[best-1]) {
			best = i + 1
		}
	}
	if best != 0 && s.lastClan >= 1 && s.lastClan <= len(s.perClan) && s.perClan[s.lastClan-1] == s.perClan[best-1] {
		return s.lastClan
	}
	return best
}

// rankOf is the rank a rating holds: 1 plus the number of players rated above it.
func rankOf(rating int) int {
	i, _, _ := ladder.Get(ladderKey(rating, ""))
	return i + 1
}
