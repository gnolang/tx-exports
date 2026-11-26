package hat

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"strconv"
)

// PickShufflers picks who shuffles, from the draw seed alone, so nobody can
// hand-pick them. Rosters of up to four use everyone, in a seed-derived
// order. Larger rosters get three distinct shufflers, never exclude.
func PickShufflers(seed []byte, n, exclude int) []int {
	pool := make([]int, 0, n)
	for i := 0; i < n; i++ {
		if n <= 4 || i != exclude {
			pool = append(pool, i)
		}
	}
	k := len(pool)
	if n > 4 {
		k = Shufflers
	}
	// Partial Fisher-Yates driven by sha256(seed || "pick" || j).
	for j := 0; j < k; j++ {
		r := j + int(draw(seed, j)%uint64(len(pool)-j))
		pool[j], pool[r] = pool[r], pool[j]
	}
	return pool[:k]
}

func draw(seed []byte, j int) uint64 {
	buf := append(append([]byte{}, seed...), []byte("pick")...)
	var ctr [4]byte
	binary.BigEndian.PutUint32(ctr[:], uint32(j))
	sum := sha256.Sum256(append(buf, ctr[:]...))
	return binary.BigEndian.Uint64(sum[:8])
}

// Circle arranges slot keys in one circle: sorted by sha256(seed || slot).
// The order is fixed by the realm, not by the last shuffler. Slot k gives to
// slot k+1, wrapping round, so with three or more slots nobody draws
// themselves and everyone is in one single loop.
func Circle(seed []byte, slots [][]byte) [][]byte {
	type keyed struct{ key, slot []byte }
	ks := make([]keyed, len(slots))
	for i, s := range slots {
		sum := sha256.Sum256(append(append([]byte{}, seed...), s...))
		ks[i] = keyed{sum[:], s}
	}
	// Insertion sort: at most MaxPeople items.
	for i := 1; i < len(ks); i++ {
		for j := i; j > 0 && bytes.Compare(ks[j].key, ks[j-1].key) < 0; j-- {
			ks[j], ks[j-1] = ks[j-1], ks[j]
		}
	}
	out := make([][]byte, len(ks))
	for i, k := range ks {
		out[i] = k.slot
	}
	return out
}

// Receiver returns the circle position slot k gives to.
func Receiver(k, n int) int { return (k + 1) % n }

// Santa returns the circle position that gives to slot k.
func Santa(k, n int) int { return (k + n - 1) % n }

// CheckMix compares one shuffle turn's output with its input. It returns ""
// if the output is a plausible shuffle (same count, every item exactly
// size bytes, all distinct), or a plain-words reason why it is not.
// It cannot tell whether each layer was peeled honestly; the phones check
// that afterwards.
func CheckMix(in, out [][]byte, size int) string {
	if len(out) != len(in) {
		return "slip count changed from " + strconv.Itoa(len(in)) + " to " + strconv.Itoa(len(out))
	}
	seen := map[string]bool{}
	for _, b := range out {
		if len(b) != size || len(b) > MaxBlob {
			return "a slip has the wrong size"
		}
		if seen[string(b)] {
			return "a slip is duplicated"
		}
		seen[string(b)] = true
	}
	return ""
}

// MatchSlips takes the last round-two output, where each item is a 32-byte
// slot key followed by a sealed slip, and lines the slips up with the circle.
// Every slot must get exactly one slip.
func MatchSlips(slots, out [][]byte) ([][]byte, string) {
	pos := map[string]int{}
	for k, s := range slots {
		pos[string(s)] = k
	}
	slips := make([][]byte, len(slots))
	for _, b := range out {
		k, ok := pos[string(b[:KeySize])]
		if !ok {
			return nil, "a slip is addressed to no slot"
		}
		if slips[k] != nil {
			return nil, "a slot got two slips"
		}
		slips[k] = b[KeySize:]
	}
	return slips, ""
}

// Fingerprint is the short public name of a key: its first 6 hex chars.
func Fingerprint(b []byte) string {
	const hexdigits = "0123456789abcdef"
	out := make([]byte, 0, 6)
	for i := 0; i < 3 && i < len(b); i++ {
		out = append(out, hexdigits[b[i]>>4], hexdigits[b[i]&15])
	}
	return string(out)
}
