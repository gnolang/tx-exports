// Package arisan holds the stateless building blocks of an arisan: the
// Indonesian rotating savings circle (a ROSCA). Every round each member puts
// the same amount into the pot and one member who has not won yet takes the
// whole pot home, until everybody has had a turn.
//
// The package keeps no state. It only provides the pieces any realm needs to
// run a circle, so other realms can reuse them with their own storage, token
// or rules:
//
//   - Mode, ParseMode: how the next winner is chosen (giliran / kocok)
//   - MixEntropy, PickIndex, PickWinner: deterministic, auditable selection
//   - FormatGNOT, ShortAddr, ProgressBar: small rendering helpers
//   - Wheel: an SVG "arisan wheel" that gnoweb renders inline
//
// The reference realm built on it is r/<namespace>/arisanku.
package arisan

import (
	"crypto/sha256"
	"strconv"
	"strings"
)

// Mode decides how the winner of a round is chosen.
type Mode int

const (
	// ModeGiliran ("taking turns"): the earliest-joined eligible member who
	// has not won yet receives the pot. Fully predictable, zero trust.
	ModeGiliran Mode = iota
	// ModeKocok ("shake the jar"): the winner is drawn among eligible members
	// from on-chain entropy, like shaking the rolled-up names in a glass jar.
	ModeKocok
)

// String returns the canonical, lowercase name of the mode.
func (m Mode) String() string {
	switch m {
	case ModeGiliran:
		return "giliran"
	case ModeKocok:
		return "kocok"
	}
	return "unknown"
}

// Label returns a human label for UIs, in Indonesian with an English gloss.
func (m Mode) Label() string {
	switch m {
	case ModeGiliran:
		return "Giliran (fixed turns)"
	case ModeKocok:
		return "Kocok (random draw)"
	}
	return "Unknown"
}

// ParseMode accepts "giliran"/"rotation"/"turns" and "kocok"/"draw"/"random"
// (case-insensitive). ok is false for anything else.
func ParseMode(s string) (m Mode, ok bool) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "giliran", "rotation", "turns", "turn", "0":
		return ModeGiliran, true
	case "kocok", "draw", "random", "lottery", "1":
		return ModeKocok, true
	}
	return ModeGiliran, false
}

// MixEntropy folds parts into the previous seed with SHA-256 and returns the
// new 32-byte seed. Feeding every payment (payer, height, time) into the seed
// makes the final draw depend on the whole round's history, not on a single
// caller.
func MixEntropy(prev []byte, parts ...string) []byte {
	buf := make([]byte, 0, len(prev)+64)
	buf = append(buf, prev...)
	for _, p := range parts {
		// length-prefix every part so ("ab","c") != ("a","bc")
		buf = append(buf, []byte(strconv.Itoa(len(p)))...)
		buf = append(buf, ':')
		buf = append(buf, []byte(p)...)
	}
	sum := sha256.Sum256(buf)
	return sum[:]
}

// PickIndex maps a seed to an index in [0, n). It uses the first 8 bytes of
// the seed as a big-endian uint64. It panics if n <= 0.
func PickIndex(seed []byte, n int) int {
	if n <= 0 {
		panic("arisan: PickIndex needs n > 0")
	}
	var x uint64
	for i := 0; i < 8 && i < len(seed); i++ {
		x = x<<8 | uint64(seed[i])
	}
	return int(x % uint64(n))
}

// PickWinner returns one element of candidates (member indexes, in join
// order). In ModeGiliran it is the first candidate; in ModeKocok it is chosen
// by PickIndex(seed). It returns -1 when there is no candidate.
func PickWinner(mode Mode, candidates []int, seed []byte) int {
	if len(candidates) == 0 {
		return -1
	}
	if mode == ModeKocok {
		return candidates[PickIndex(seed, len(candidates))]
	}
	return candidates[0]
}

// FormatGNOT renders an amount of ugnot as GNOT with up to 6 decimals and no
// trailing zeros: 1500000 -> "1.5 GNOT", 250 -> "0.00025 GNOT".
func FormatGNOT(ugnot int64) string {
	neg := ugnot < 0
	if neg {
		ugnot = -ugnot
	}
	whole := ugnot / 1000000
	frac := ugnot % 1000000
	s := strconv.FormatInt(whole, 10)
	if frac != 0 {
		f := strconv.FormatInt(frac, 10)
		for len(f) < 6 {
			f = "0" + f
		}
		f = strings.TrimRight(f, "0")
		s += "." + f
	}
	if neg {
		s = "-" + s
	}
	return s + " GNOT"
}

// ShortAddr shortens a bech32 address for display: g1abcd…wxyz.
func ShortAddr(addr string) string {
	if len(addr) <= 13 {
		return addr
	}
	return addr[:6] + "…" + addr[len(addr)-4:]
}

// ProgressBar renders done/total as a fixed-width text bar, e.g.
// ProgressBar(2, 5, 10) == "▰▰▰▰▱▱▱▱▱▱".
func ProgressBar(done, total, width int) string {
	if width <= 0 {
		return ""
	}
	if total <= 0 {
		return strings.Repeat("▱", width)
	}
	if done < 0 {
		done = 0
	}
	if done > total {
		done = total
	}
	filled := done * width / total
	return strings.Repeat("▰", filled) + strings.Repeat("▱", width-filled)
}
