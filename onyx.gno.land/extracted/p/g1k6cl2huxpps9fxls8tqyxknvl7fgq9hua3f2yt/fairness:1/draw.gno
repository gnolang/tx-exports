package fairness

// Deterministic draw: a seed-driven byte stream and a weighted, multi-winner
// sample taken from it without replacement.
//
// Everything here is a pure function of its inputs, so the same seed over the
// same roster gives the same winners wherever it is recomputed — in a realm,
// in a test, or in a verifier script off chain.

import (
	"errors"
	"strconv"
)

// maxUint64 is 2^64-1.
const maxUint64 uint64 = 1<<64 - 1

// Ticket is one entry in a draw.
//
// ID is the entrant's stable identity — FairDrop uses the bech32 address
// string, so the roster is ordered and deduplicated by address. Commit is the
// seal, Secret the revealed preimage (empty until reveal) and Rank 0 until the
// draw, then 1..k for winners. The package only reads ID, Weight and Commit;
// Secret and Rank are carried so a realm can keep one record per ticket.
type Ticket struct {
	ID     string
	Weight uint64
	Commit string
	Secret string
	Rank   int
}

// Insert adds t to a roster kept in canonical (ascending ID) order and refuses
// an ID that is already present. One call therefore enforces both rules a
// draw depends on: a single ticket per entrant, and the fixed ordering the
// seed fold and the draw walk over.
//
// The returned slice is a new slice; the caller must keep it.
func Insert(roster []Ticket, t Ticket) ([]Ticket, error) {
	if t.ID == "" {
		return roster, errors.New("fairness: empty entrant id")
	}
	if t.Weight == 0 {
		return roster, errors.New("fairness: weight must be positive")
	}

	n := len(roster)
	lo, hi := 0, n
	for lo < hi {
		mid := (lo + hi) / 2
		if roster[mid].ID < t.ID {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < n && roster[lo].ID == t.ID {
		return roster, errors.New("fairness: entrant already holds a ticket")
	}

	out := make([]Ticket, n+1)
	for i := 0; i < lo; i++ {
		out[i] = roster[i]
	}
	out[lo] = t
	for i := lo; i < n; i++ {
		out[i+1] = roster[i]
	}
	return out, nil
}

// Find returns the index of the ticket held by id, or -1.
func Find(roster []Ticket, id string) int {
	lo, hi := 0, len(roster)
	for lo < hi {
		mid := (lo + hi) / 2
		if roster[mid].ID < id {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(roster) && roster[lo].ID == id {
		return lo
	}
	return -1
}

// Stream is a deterministic byte stream: SHA-256 in counter mode over the
// seed. It exists so a draw needs no randomness from the chain, which is what
// makes the result reproducible by anyone holding the seed.
type Stream struct {
	seed string
	ctr  uint64
	pool []byte
	pos  int
}

// NewStream starts a stream at seed.
func NewStream(seed string) *Stream {
	return &Stream{seed: seed}
}

func (s *Stream) refill() {
	sum := sha256Sum(s.seed + "|" + strconv.FormatUint(s.ctr, 10))
	s.ctr++
	s.pool = sum
	s.pos = 0
}

// Uint64 returns the next 8 stream bytes as a big-endian unsigned integer.
func (s *Stream) Uint64() uint64 {
	if s.pool == nil || s.pos+8 > len(s.pool) {
		s.refill()
	}
	var v uint64
	for i := 0; i < 8; i++ {
		v = (v << 8) | uint64(s.pool[s.pos+i])
	}
	s.pos += 8
	return v
}

// Below returns a uniform integer in [0, n) by rejection sampling, so no
// residue is favoured by the modulo. It panics on n == 0.
func (s *Stream) Below(n uint64) uint64 {
	if n == 0 {
		panic("fairness: Below(0)")
	}
	limit := (maxUint64 / n) * n
	for {
		v := s.Uint64()
		if v < limit {
			return v % n
		}
	}
}

// Draw samples up to k distinct tickets from roster, without replacement,
// with probability proportional to Weight, and returns their IDs in the order
// they were drawn (index 0 is rank 1). Zero-weight tickets are never drawn.
//
// The order of roster must be canonical (as Insert maintains it), because the
// stream walks the roster in that order.
func Draw(seed string, roster []Ticket, k int) []string {
	if k <= 0 || len(roster) == 0 {
		return []string{}
	}
	if k > len(roster) {
		k = len(roster)
	}

	// Work on a copy so the caller's roster (realm state) is untouched.
	pool := make([]Ticket, len(roster))
	for i := 0; i < len(roster); i++ {
		pool[i] = roster[i]
	}

	s := NewStream(seed)
	winners := make([]string, 0, k)
	for len(winners) < k {
		var total uint64
		for i := 0; i < len(pool); i++ {
			w := pool[i].Weight
			if w > 0 && total > maxUint64-w {
				panic("fairness: total weight overflows uint64")
			}
			total += w
		}
		if total == 0 {
			break
		}

		pick := s.Below(total)
		at := -1
		var acc uint64
		for i := 0; i < len(pool); i++ {
			if pool[i].Weight == 0 {
				continue
			}
			acc += pool[i].Weight
			if pick < acc {
				at = i
				break
			}
		}
		if at < 0 {
			// Unreachable while total > 0, kept as a hard stop rather than a
			// silent wrong pick.
			panic("fairness: weighted pick fell through")
		}

		winners = append(winners, pool[at].ID)

		kept := make([]Ticket, 0, len(pool)-1)
		for i := 0; i < len(pool); i++ {
			if i != at {
				kept = append(kept, pool[i])
			}
		}
		pool = kept
	}
	return winners
}

// TotalWeight sums the weights of a roster, panicking rather than wrapping.
func TotalWeight(roster []Ticket) uint64 {
	var total uint64
	for i := 0; i < len(roster); i++ {
		w := roster[i].Weight
		if w > 0 && total > maxUint64-w {
			panic("fairness: total weight overflows uint64")
		}
		total += w
	}
	return total
}
