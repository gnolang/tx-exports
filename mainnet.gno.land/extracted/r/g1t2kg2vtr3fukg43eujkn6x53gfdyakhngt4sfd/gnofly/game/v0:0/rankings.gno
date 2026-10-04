package game

import "strings"

// ranking is a leaderboard on a single number that only goes up, the count of
// kills: the top players, best first, at most leaderboard_size lines and one
// line per player. With equal scores, the player who got there first stays
// ahead.
//
// It is kept sorted at write time, so reading it never has to look at every
// player. Scores only going up is what makes that exact: a player outside
// the list can only enter it through raise.
//
// The two slices are parallel: slices of plain values are one stored object
// each, where a slice of structs would be one object per line. Measured on
// gnodev, a line costs about 190 bytes this way.
type ranking struct {
	addrs  []address
	scores []int64
}

// leaderboardSize returns how many lines a leaderboard may hold.
func leaderboardSize() int {
	return int(findParam(paramLeaderboardSize).value)
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
// with exactly old, which the binary search finds without reading the whole
// list: with 32 players credited in one call on a 100 line list, comparing
// every address would cost millions of gas. A player whose score was zero
// has never been through raise and has no line.
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

// spliceAddrs returns a copy of a leaderboard column with v inserted at index
// to. With from >= 0 the element at that index, the player's previous line,
// is left out; to must not be past it. With from < 0 the result is kept to
// size elements by dropping the tail; to must be below size.
//
// The copy has exactly the length of its content, so that nothing else stays
// in storage, and it is built with the append builtin: on a 100 line board a
// loop over the lines costs several times more gas.
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

// cut returns the first size lines of the ranking, in slices of exactly that
// length, so that nothing beyond the kept lines stays in storage.
func (r ranking) cut(size int) ranking {
	n := len(r.addrs)
	if n > size {
		n = size
	}
	out := ranking{addrs: make([]address, n), scores: make([]int64, n)}
	copy(out.addrs, r.addrs)
	copy(out.scores, r.scores)
	return out
}

// trimRankings cuts the kill leaderboard down to leaderboard_size.
func trimRankings() {
	if size := leaderboardSize(); len(killers.addrs) > size {
		killers = killers.cut(size)
	}
}

// writeRanking writes a ranking as a JSON array of
// {"address":"g1...","<key>":<score>} objects, best first.
func writeRanking(b *strings.Builder, r ranking, key string) {
	b.WriteByte('[')
	for i, addr := range r.addrs {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"address":"`)
		b.WriteString(addr.String())
		b.WriteString(`","`)
		b.WriteString(key)
		b.WriteString(`":`)
		b.WriteString(itoa(r.scores[i]))
		b.WriteByte('}')
	}
	b.WriteByte(']')
}
