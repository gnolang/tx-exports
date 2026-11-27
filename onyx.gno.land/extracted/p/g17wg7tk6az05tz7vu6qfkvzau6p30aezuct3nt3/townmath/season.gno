package townmath

// PayoutBps is the share of the season pot paid to ranks 1..10, in basis
// points. It sums to 10000.
var PayoutBps = [10]int64{3000, 2000, 1400, 1000, 800, 600, 450, 300, 250, 200}

// Payout returns the prize for a rank (1 to 10) from the pot in ugnot.
// Ranks outside 1..10 and non-positive pots pay 0. Rounding is floor, so the
// total paid never exceeds the pot.
func Payout(potUgnot int64, rank int) int64 {
	if rank < 1 || rank > 10 || potUgnot <= 0 {
		return 0
	}
	return MulBps(potUgnot, PayoutBps[rank-1])
}

// SeasonScore ranks taverns: profit in copper-gold / 100 plus twice the
// reputation.
func SeasonScore(profitCg, rep int64) int64 {
	return profitCg/100 + rep*2
}

// CapGain limits growth per step: min(next, prev+cap). A negative cap is
// treated as 0 so a bad argument cannot push the value below prev.
func CapGain(prev, next, cap int64) int64 {
	if cap < 0 {
		cap = 0
	}
	return min64(next, prev+cap)
}

// SplitPayment splits a payment into the season pot share (potBps of amount,
// rounded down) and the treasury remainder, so pot + treasury == amount.
// potBps is clamped to 0..10000; a non-positive amount splits to (0, 0).
func SplitPayment(amount, potBps int64) (pot, treasury int64) {
	if amount <= 0 {
		return 0, 0
	}
	pot = MulBps(amount, clamp(potBps, 0, BpsOne))
	return pot, amount - pot
}

// Entry is one leaderboard row.
type Entry struct {
	Owner string
	Score int64
}

// UpdateTop returns a new leaderboard with e applied: any existing entry for
// the same owner is replaced by e (new score, even if lower), the list is
// sorted by score descending with ties keeping the earlier entry first, and
// it is truncated to n. top is never modified. n <= 0 returns an empty
// slice; an entry with an empty owner is ignored.
func UpdateTop(top []Entry, e Entry, n int) []Entry {
	out := make([]Entry, 0, len(top)+1)
	if n <= 0 {
		return out
	}
	// copy everything except the owner's old entry
	for i := 0; i < len(top); i++ {
		if e.Owner != "" && top[i].Owner == e.Owner {
			continue
		}
		out = append(out, top[i])
	}
	if e.Owner != "" {
		// insert after every entry whose score is >= e.Score
		pos := len(out)
		for i := 0; i < len(out); i++ {
			if out[i].Score < e.Score {
				pos = i
				break
			}
		}
		out = append(out, Entry{})
		for i := len(out) - 1; i > pos; i-- {
			out[i] = out[i-1]
		}
		out[pos] = e
	}
	if len(out) > n {
		out = out[:n]
	}
	return out
}

// InsertTop applies e to the leaderboard held in buf[:length] in place and
// returns the new length. The result buf[:new length] is exactly
// UpdateTop(buf[:length], e, len(buf)): the owner's old entries are removed,
// e is inserted after every entry with a score >= e.Score, and the list is
// cut to len(buf). It allocates nothing, so a realm can keep its board in a
// fixed array and update it with element writes. length is clamped to
// 0..len(buf); an entry with an empty owner changes nothing. Loops are
// bounded by len(buf).
func InsertTop(buf []Entry, length int, e Entry) int {
	n := len(buf)
	if n <= 0 {
		return 0
	}
	if length < 0 {
		length = 0
	}
	if length > n {
		length = n
	}
	if e.Owner == "" {
		return length
	}
	// remove every old entry of the owner, keeping the order of the rest
	k := 0
	for i := 0; i < length; i++ {
		if buf[i].Owner == e.Owner {
			continue
		}
		if k != i {
			buf[k] = buf[i]
		}
		k++
	}
	for i := k; i < length; i++ {
		buf[i] = Entry{}
	}
	length = k
	pos := length
	for i := 0; i < length; i++ {
		if buf[i].Score < e.Score {
			pos = i
			break
		}
	}
	if pos >= n {
		return length // full and e ranks last: dropped, as UpdateTop cuts it
	}
	end := length
	if end == n {
		end = n - 1 // the last entry falls off
	}
	for j := end; j > pos; j-- {
		buf[j] = buf[j-1]
	}
	buf[pos] = e
	if length < n {
		length++
	}
	return length
}
