package standings

const (
	startRating    = 1000
	maxRating      = 0xFFFF // a ladder key holds the rating in 2 bytes
	playerK        = 32
	clanK          = 16
	maxClans       = 255    // a clan number fills one byte of a standing and a result entry
	maxPlayerCount = 0xFFFF // a player's counts are stored in 2 bytes
	maxClanCount   = 0xFFFFFFFF
)

// clanRecord is a clan's rating and its record in rated matches against other clans.
type clanRecord struct {
	name                        string
	rating, wins, losses, draws int
}

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

// rate counts a match between a, playing clan number ca, and b, playing clan number cb,
// in which a scored score thousandths: in both standings, on the ladder, and in the clan
// records when both clans are counted and differ.
func rate(a, b address, ca, cb, score int) {
	sa, sb := ratedStanding(a), ratedStanding(b)
	sa.rating, sb.rating = applyChange(sa.rating, sb.rating, eloChange(sa.rating, sb.rating, score, playerK))
	sa.count(score, ca)
	sb.count(1000-score, cb)
	ladder, _ = ladder.Set(ladderKey(sa.rating, a), nil)
	ladder, _ = ladder.Set(ladderKey(sb.rating, b), nil)
	saveStanding(a, sa)
	saveStanding(b, sb)

	if ca == cb || ca == 0 || cb == 0 {
		return
	}
	x, y := &clans[ca-1], &clans[cb-1]
	x.rating, y.rating = applyChange(x.rating, y.rating, eloChange(x.rating, y.rating, score, clanK))
	tally(score, &x.wins, &x.losses, &x.draws, maxClanCount)
	tally(1000-score, &y.wins, &y.losses, &y.draws, maxClanCount)
}

// ratedStanding returns a's standing, created at startRating for a first rated match, and
// takes its key off the ladder until it is counted.
func ratedStanding(a address) *standing {
	st := loadStanding(a)
	if st == nil {
		st = &standing{rating: startRating}
	} else {
		ladder, _, _, _ = ladder.Remove(ladderKey(st.rating, a))
	}
	return st
}

// loadStanding returns a's standing, nil before their first rated match.
func loadStanding(a address) *standing {
	return decodeStanding(stringAt(&players, string(a)))
}

func saveStanding(a address, st *standing) {
	players.Set(string(a), encodeStanding(st))
}

// clanNumber is the clan number of name, its first-seen position plus one. A name not
// seen before gets the next number, or 0, no clan, once maxClans are numbered: a writer
// that fills the table must not abort another writer's endings.
func clanNumber(name string) int {
	for i, c := range clans {
		if c.name == name {
			return i + 1
		}
	}
	if len(clans) == maxClans {
		return 0
	}
	clans = append(clans, clanRecord{name: name, rating: startRating})
	return len(clans)
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

// count adds a match scored score thousandths and played as clan number clan, 0 for none.
// perClan grows only as far as the clan numbers s has played.
func (s *standing) count(score, clan int) {
	tally(score, &s.wins, &s.losses, &s.draws, maxPlayerCount)
	s.lastClan = clan
	if clan == 0 {
		return
	}
	for len(s.perClan) < clan {
		s.perClan = append(s.perClan, 0)
	}
	if s.perClan[clan-1] < maxPlayerCount {
		s.perClan[clan-1]++
	}
}

// tally adds a win, loss or draw for score, each count stopping at ceiling.
func tally(score int, wins, losses, draws *int, ceiling int) {
	n := draws
	switch score {
	case 1000:
		n = wins
	case 0:
		n = losses
	}
	if *n < ceiling {
		*n++
	}
}

// mainClan is the clan number s has finished the most rated matches with, 0 for none. A
// tie goes to the last match's clan when it is one of the tied, else to first-seen order.
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
