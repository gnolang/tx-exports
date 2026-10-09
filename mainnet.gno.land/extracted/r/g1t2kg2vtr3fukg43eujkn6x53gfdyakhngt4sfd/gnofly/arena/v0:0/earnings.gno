package arena

import "gno.land/p/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/arena/payout/v0"

// Earnings are what players won, added up round after round. Like the
// results they are a record for readers: no payment is ever computed from
// them.
//
// For one settled round a player's winnings are what they were paid above
// their own stake, and never less than zero: losing a stake does not take
// anything back from what was won before. Cancelled and refunded rounds
// count for nothing, nobody won or lost in them.

// topSize is how many players the list of top winners holds.
const topSize = 10

// totals is what the realm remembers about one player.
type totals struct {
	won    int64 // ugnot won above the stakes, over every settled round
	rounds int64 // settled rounds played
}

// Totals are stored as a single string, "won:rounds", for the same reason
// as the pilots of the game realm: a struct would be one more stored object
// per player, and the referee pays for up to 16 new players per settlement.

// encode returns the stored form of t.
func (t totals) encode() string {
	return itoa(t.won) + ":" + itoa(t.rounds)
}

// totalsOf returns the totals of a player, zero for a player who never
// finished a round.
func totalsOf(addr address) totals {
	v := earnings.Get(addr.String())
	if v == nil {
		return totals{}
	}
	s := v.(string)
	colon := indexFrom(s, 0, ':')
	if colon == len(s) {
		panic(errCorruptEarnings)
	}
	won, ok := digits(s[:colon])
	if !ok {
		panic(errCorruptEarnings)
	}
	rounds, ok := digits(s[colon+1:])
	if !ok {
		panic(errCorruptEarnings)
	}
	return totals{won: won, rounds: rounds}
}

// creditRound records a settled round for each of its players: one more
// round played, and what they were paid above their stake, if anything.
func creditRound(stake int64, players []address, payouts []payout.Payout) {
	for _, p := range players {
		gain := int64(0)
		for _, paid := range payouts {
			if paid.Address == p && paid.Amount > stake {
				gain = paid.Amount - stake
			}
		}

		t := totalsOf(p)
		before := t.won
		t.won += gain
		t.rounds++
		earnings.Set(p.String(), t.encode())

		if gain > 0 {
			if next, changed := winners.raise(p, before, t.won, topSize); changed {
				winners = next
			}
		}
	}
}

// ranking is the list of top winners: the players who won the most, best
// first, at most topSize lines and one line per player. With equal winnings,
// the player who got there first stays ahead.
//
// It is the ranking of the game realm. It is kept sorted at write time, so
// reading it never has to look at every player. Winnings only going up is
// what makes that exact: a player outside the list can only enter it through
// raise.
//
// The two slices are parallel: slices of plain values are one stored object
// each, where a slice of structs would be one object per line.
type ranking struct {
	addrs  []address
	scores []int64
}

// raise puts a player at their place after their score went up from old to
// score. It returns the ranking to store, and changed == false when it is
// left as it is: the player is not on a full list and still not good enough
// to get on.
func (r ranking) raise(addr address, old, score int64, size int) (next ranking, changed bool) {
	from := r.lineOf(addr, old)
	to := r.search(score - 1) // after every line with this score or more
	if from < 0 && to >= size {
		return r, false
	}
	if from >= 0 && to > from {
		to = from // cannot happen: a score only goes up
	}
	next = ranking{
		addrs:  spliceAddrs(r.addrs, from, to, addr, size),
		scores: spliceInts(r.scores, from, to, score, size),
	}
	return next, true
}

// search returns the index of the first line with a score of limit or less,
// the number of lines when there is none. The list is sorted, so this is a
// binary search.
func (r ranking) search(limit int64) int {
	lo, hi := 0, len(r.scores)
	for lo < hi {
		mid := (lo + hi) / 2
		if r.scores[mid] <= limit {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return lo
}

// lineOf returns the index of a player's line, -1 when they have none. old
// is the player's score before the change being applied.
//
// A line always carries the current score of its player, because every
// change of a score goes through raise. So the line can only be among those
// with exactly old. A player whose score was zero has never been through
// raise and has no line.
func (r ranking) lineOf(addr address, old int64) int {
	if old <= 0 {
		return -1
	}
	for i := r.search(old); i < len(r.scores) && r.scores[i] == old; i++ {
		if r.addrs[i] == addr {
			return i
		}
	}
	return -1
}

// spliceAddrs returns a copy of a ranking column with v inserted at index
// to. With from >= 0 the element at that index, the player's previous line,
// is left out; to must not be past it. With from < 0 the result is kept to
// size elements by dropping the tail; to must be below size.
//
// The copy has exactly the length of its content, so that nothing else stays
// in storage.
func spliceAddrs(list []address, from, to int, v address, size int) []address {
	if from < 0 {
		if len(list) >= size {
			list = list[:size-1]
		}
		out := make([]address, 0, len(list)+1)
		out = append(out, list[:to]...)
		out = append(out, v)
		return append(out, list[to:]...)
	}
	out := make([]address, 0, len(list))
	out = append(out, list[:to]...)
	out = append(out, v)
	out = append(out, list[to:from]...)
	return append(out, list[from+1:]...)
}

// spliceInts is spliceAddrs for a column of numbers.
func spliceInts(list []int64, from, to int, v int64, size int) []int64 {
	if from < 0 {
		if len(list) >= size {
			list = list[:size-1]
		}
		out := make([]int64, 0, len(list)+1)
		out = append(out, list[:to]...)
		out = append(out, v)
		return append(out, list[to:]...)
	}
	out := make([]int64, 0, len(list))
	out = append(out, list[:to]...)
	out = append(out, v)
	out = append(out, list[to:from]...)
	return append(out, list[from+1:]...)
}
