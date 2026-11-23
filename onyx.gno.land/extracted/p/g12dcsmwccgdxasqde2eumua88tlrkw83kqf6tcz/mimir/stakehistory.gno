// Package mimir holds the pure helpers Mimir's market realms share: stake
// history checkpoints (settlement cutoffs) and overflow-safe arithmetic.
package mimir

// Amounts are cumulative net deposits on each side, and the copied part of each.
type Amounts struct {
	A, B, CopiedA, CopiedB int64
}

type Checkpoint struct {
	At      int64 // unix seconds
	Amounts Amounts
}

// History is an append-only list of checkpoints in time order. Deposits in the
// same second coalesce into one checkpoint. Settlement never scans all deposits.
type History struct {
	points []Checkpoint
}

// Record stores the running totals as of `now`.
func (h *History) Record(now int64, a Amounts) {
	n := len(h.points)
	if n != 0 && h.points[n-1].At == now {
		h.points[n-1].Amounts = a
		return
	}
	h.points = append(h.points, Checkpoint{At: now, Amounts: a})
}

// Before returns the totals recorded strictly before cutoff. A cutoff of 0
// means no cutoff: the latest totals.
func (h *History) Before(cutoff int64) Amounts {
	hi := len(h.points)
	if hi == 0 {
		return Amounts{}
	}
	if cutoff == 0 {
		return h.points[hi-1].Amounts
	}
	lo := 0
	for lo < hi {
		mid := lo + (hi-lo)/2
		if h.points[mid].At < cutoff {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 {
		return Amounts{}
	}
	return h.points[lo-1].Amounts
}

func (h *History) Len() int { return len(h.points) }
