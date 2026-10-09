package ledger

// Equal splits total into n parts that differ by at most one cent; the first
// total%n parts take the extra cent. A negative total (money received) splits
// the same way, every part negative.
func Equal(total int64, n int) []int64 {
	w := make([]int64, n)
	for i := range w {
		w[i] = 1
	}
	return Weighted(total, w)
}

// Weighted splits total in proportion to weights, all positive, by largest
// remainder: each part is rounded down, then the cents left go to the largest
// remainders, ties to the first. The parts always sum to total.
func Weighted(total int64, weights []int64) []int64 {
	neg := total < 0
	if neg {
		total = -total
	}
	var sum int64
	for _, w := range weights {
		sum += w
	}
	parts := make([]int64, len(weights))
	rem := make([]int64, len(weights))
	left := total
	for i, w := range weights {
		parts[i] = total * w / sum
		rem[i] = total * w % sum
		left -= parts[i]
	}
	for ; left > 0; left-- {
		best := 0
		for i := 1; i < len(rem); i++ {
			if rem[i] > rem[best] {
				best = i
			}
		}
		parts[best]++
		rem[best] = -1 // one extra cent at most per part
	}
	if neg {
		for i := range parts {
			parts[i] = -parts[i]
		}
	}
	return parts
}

// Transfer is one payment that settles part of a group: From pays To.
type Transfer struct {
	From, To int
	Amount   int64
}

// Settle returns the transfers that bring every balance to zero (balances
// sum to zero; > 0 means the group owes that member). The largest debt pays
// the largest credit, ties to the lower index, so each step clears at least
// one member: at most n-1 transfers, in O(n²) for the few members of a group.
func Settle(balances []int64) []Transfer {
	bal := make([]int64, len(balances))
	copy(bal, balances)
	var out []Transfer
	for {
		cr, dr := -1, -1
		for i, b := range bal {
			if b > 0 && (cr < 0 || b > bal[cr]) {
				cr = i
			}
			if b < 0 && (dr < 0 || b < bal[dr]) {
				dr = i
			}
		}
		if cr < 0 || dr < 0 {
			return out
		}
		amt := bal[cr]
		if -bal[dr] < amt {
			amt = -bal[dr]
		}
		out = append(out, Transfer{From: dr, To: cr, Amount: amt})
		bal[cr] -= amt
		bal[dr] += amt
	}
}
