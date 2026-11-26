// Package roscasched derives the payout order of a rotating savings circle.
//
// The order is a Fisher-Yates shuffle over SHA-256(circle id | activation
// height | sorted member addresses): deterministic on every node, and not
// choosable by the circle's creator.
package sched2

import (
	"crypto/sha256"
	"strconv"
	"strings"
)

// Seed builds the activation seed for a circle. Mixing the circle ID, the
// activation height and the sorted member set means the payout order cannot
// be chosen by the creator after the fact, and every node derives the same
// order from the same chain state.
func Seed(circleID uint64, height int64, members []string) string {
	parts := make([]string, len(members))
	copy(parts, members)
	sortStrings(parts)
	return strconv.FormatUint(circleID, 10) + "|" +
		strconv.FormatInt(height, 10) + "|" +
		strings.Join(parts, ",")
}

// Order returns a deterministic permutation of 0..n-1 derived from seed.
//
// It is a Fisher-Yates shuffle over bytes of SHA-256(seed:counter), so the
// same seed always yields the same order on every machine and every replay.
func Order(n int, seed string) []int {
	idx := make([]int, n)
	for i := 0; i < n; i++ {
		idx[i] = i
	}
	if n < 2 {
		return idx
	}
	p := newPRNG(seed)
	for i := n - 1; i > 0; i-- {
		j := int(p.next() % uint64(i+1))
		idx[i], idx[j] = idx[j], idx[i]
	}
	return idx
}


// --- internals ---

// prng is a deterministic byte stream: SHA-256(seed:counter) concatenated.
type prng struct {
	seed string
	buf  []byte
	ctr  int
}

func newPRNG(seed string) *prng { return &prng{seed: seed} }

func (p *prng) next() uint64 {
	for len(p.buf) < 8 {
		h := sha256.Sum256([]byte(p.seed + ":" + strconv.Itoa(p.ctr)))
		p.ctr++
		p.buf = append(p.buf, h[:]...)
	}
	b := p.buf[:8]
	p.buf = p.buf[8:]
	var v uint64
	for i := 0; i < 8; i++ {
		v = v<<8 | uint64(b[i])
	}
	return v
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}
