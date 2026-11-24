// Package rankpay is a small, stateless library for contest payouts:
// parse and validate a per-place split ("50,30,20"), rank scored entries by
// a metric (higher or lower is better, ties to the earlier entry), and turn a
// pot into exact per-place shares that always sum back to the pot.
//
// It holds no coins and no state, so any realm (bounties, tournaments,
// hackathon prizes, games) can import it and keep its own escrow rules.
package rankpay

import (
	"strconv"
	"strings"
)

// MaxPlaces is the most paid places a split may have.
const MaxPlaces = 10

// ParseSplits parses "50,30,20" into percents per place. It panics unless
// there are 1..MaxPlaces positive integers that sum to 100 and never pay a
// lower place more than a higher one.
func ParseSplits(s string) []int {
	s = strings.ReplaceAll(s, " ", "")
	parts := strings.Split(s, ",")
	if s == "" || len(parts) > MaxPlaces {
		panic("splits: 1 to 10 places, e.g. 50,30,20")
	}
	out := make([]int, 0, len(parts))
	sum := 0
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n <= 0 {
			panic("splits: each place must be a positive integer percent")
		}
		if i > 0 && n > out[i-1] {
			panic("splits: a lower place cannot pay more than a higher one")
		}
		out = append(out, n)
		sum += n
	}
	if sum != 100 {
		panic("splits must sum to 100")
	}
	return out
}

// Shares splits pot by the given weights (percents). Weights need not sum
// to 100: Shares(pot, splits[:k]) pays only the first k places and spreads
// the unfilled places' shares over them pro rata. Rounding dust goes to 1st
// place, so the shares always sum exactly to pot. Integer math only
// (pot*weight must fit in int64, true for any realistic ugnot pot).
func Shares(pot int64, splits []int) []int64 {
	out := make([]int64, len(splits))
	total := int64(0)
	for _, p := range splits {
		total += int64(p)
	}
	if total <= 0 {
		return out
	}
	sum := int64(0)
	for i, p := range splits {
		out[i] = pot * int64(p) / total
		sum += out[i]
	}
	if len(out) > 0 {
		out[0] += pot - sum
	}
	return out
}

// EqualShares splits pot equally among n; dust goes to the first.
func EqualShares(pot int64, n int) []int64 {
	if n <= 0 {
		return nil
	}
	out := make([]int64, n)
	each := pot / int64(n)
	for i := range out {
		out[i] = each
	}
	out[0] += pot - each*int64(n)
	return out
}

// Rank returns the indexes of scores ordered best first. Equal scores keep
// their input order, so callers pass entries in submission order and the
// earlier submission wins a tie. Stable insertion sort: fine for the few
// hundred entries a contest holds, and deterministic for consensus.
func Rank(scores []int64, higherIsBetter bool) []int {
	idx := make([]int, len(scores))
	for i := range idx {
		idx[i] = i
	}
	for i := 1; i < len(idx); i++ {
		for j := i; j > 0 && Better(scores[idx[j]], scores[idx[j-1]], higherIsBetter); j-- {
			idx[j], idx[j-1] = idx[j-1], idx[j]
		}
	}
	return idx
}

// Better reports whether score a strictly beats score b.
func Better(a, b int64, higherIsBetter bool) bool {
	if higherIsBetter {
		return a > b
	}
	return a < b
}

// Format returns splits as "50/30/20".
func Format(splits []int) string {
	out := make([]string, len(splits))
	for i, p := range splits {
		out[i] = strconv.Itoa(p)
	}
	return strings.Join(out, "/")
}
