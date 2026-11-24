// Package rosca is a dependency-free toolkit for building rotating savings
// and credit associations (ROSCA — "arisan", "tanda", "chit fund", "susus")
// on Gno.land.
//
// It contains no state and no realm capability of its own: the economics,
// the deterministic payout schedule and the presentation helpers are pure
// functions, so any realm can import this package and add a savings circle
// to its own state machine without re-deriving the hard parts.
//
// The companion realm gno.land/r/<addr>/kolektif is the reference
// implementation; it imports exactly these helpers.
package rosca

import (
	"crypto/sha256"
	"errors"
	"strconv"
	"strings"
)

// Status is the lifecycle stage of a circle.
type Status uint8

const (
	// StatusOpen collects members and collateral. Nothing is paid out.
	StatusOpen Status = iota
	// StatusActive is a full circle that is paying round by round.
	StatusActive
	// StatusComplete means every payout happened and collateral was returned.
	StatusComplete
)

// String renders a status as a short label.
func (s Status) String() string {
	switch s {
	case StatusOpen:
		return "OPEN"
	case StatusActive:
		return "ACTIVE"
	case StatusComplete:
		return "COMPLETE"
	}
	return "UNKNOWN"
}

// Limits keep a circle inside numbers the reference realm can render and
// settle safely. They are advisory: an importing realm may enforce others.
const (
	MinSize          = 3
	MaxSize          = 50
	MinContribution  = int64(1000)         // 0.001 GNOT
	MaxContribution  = int64(100000000000) // 100,000 GNOT
	MinRoundSpan     = int64(60)           // 1 minute
	MaxRoundSpan     = int64(2592000)      // 30 days
	MaxNameLen       = 64
	DefaultRoundSpan = int64(604800) // 7 days
	UgnotPerGnot     = int64(1000000)
)

// Params is the immutable economics of a circle.
//
// Contribution is what each member pays every round. Collateral is what a
// member locks when joining; it is returned at completion and slashed into
// the penalty fund when the member defaults.
type Params struct {
	Contribution int64
	Collateral   int64
	Size         int
	RoundSpan    int64 // seconds per round
}

// Validate checks the parameters of a circle.
func (p Params) Validate() error {
	if p.Size < MinSize || p.Size > MaxSize {
		return errors.New("size must be between 3 and 50 members")
	}
	if p.Contribution < MinContribution || p.Contribution > MaxContribution {
		return errors.New("contribution out of range")
	}
	if p.Collateral != p.Contribution {
		return errors.New("collateral must equal one round contribution")
	}
	if p.RoundSpan < MinRoundSpan || p.RoundSpan > MaxRoundSpan {
		return errors.New("round span must be between 1 minute and 30 days")
	}
	return nil
}

// Pot is the payout one round produces when every seat pays.
func (p Params) Pot() int64 {
	return p.Contribution * int64(p.Size)
}

// Locked is the capital a circle needs at rest: every seat's collateral.
func (p Params) Locked() int64 {
	return p.Collateral * int64(p.Size)
}

// NetPerMember is the net cash flow of an ideal circle (no defaults) for a
// member who stays to the end: they pay Size contributions and receive one
// pot of Size contributions. It is always zero, which is the point of a
// ROSCA: it is a savings rotation, not a loan.
func (p Params) NetPerMember() int64 {
	return p.Pot() - p.Contribution*int64(p.Size)
}

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

// Split divides amount into n shares. Any remainder goes one unit at a time
// to the first shares, so the shares always add up to amount exactly.
func Split(amount int64, n int) []int64 {
	out := make([]int64, n)
	if n <= 0 || amount <= 0 {
		return out
	}
	base := amount / int64(n)
	rem := amount % int64(n)
	for i := 0; i < n; i++ {
		out[i] = base
	}
	for i := 0; int64(i) < rem; i++ {
		out[i]++
	}
	return out
}

// Gnot formats a ugnot amount as GNOT with up to six decimals and no
// trailing zeros: 1500000 -> "1.5", 1000 -> "0.001".
func Gnot(ugnot int64) string {
	neg := ugnot < 0
	if neg {
		ugnot = -ugnot
	}
	whole := ugnot / UgnotPerGnot
	frac := ugnot % UgnotPerGnot
	s := strconv.FormatInt(whole, 10)
	if frac > 0 {
		f := strconv.FormatInt(frac+UgnotPerGnot, 10)[1:] // zero padded, 6 digits
		f = strings.TrimRight(f, "0")
		s += "." + f
	}
	if neg {
		s = "-" + s
	}
	return s
}

// HumanDuration renders a number of seconds as a compact human string:
// 90061 -> "1d 1h", 3600 -> "1h", 45 -> "45s".
func HumanDuration(seconds int64) string {
	if seconds <= 0 {
		return "now"
	}
	d := seconds / 86400
	h := (seconds % 86400) / 3600
	m := (seconds % 3600) / 60
	s := seconds % 60
	out := ""
	if d > 0 {
		out += strconv.FormatInt(d, 10) + "d "
	}
	if h > 0 && d < 100 {
		out += strconv.FormatInt(h, 10) + "h "
	}
	if m > 0 && d == 0 {
		out += strconv.FormatInt(m, 10) + "m "
	}
	if s > 0 && d == 0 && h == 0 {
		out += strconv.FormatInt(s, 10) + "s"
	}
	return strings.TrimSpace(out)
}

// Bar renders a fixed width progress bar, e.g. "███░░░░░".
func Bar(done, total, width int) string {
	if width <= 0 {
		return ""
	}
	if total <= 0 || done <= 0 {
		return strings.Repeat("░", width)
	}
	if done > total {
		done = total
	}
	filled := done * width / total
	if filled == 0 {
		filled = 1
	}
	if filled > width {
		filled = width
	}
	return strings.Repeat("█", filled) + strings.Repeat("░", width-filled)
}

// ShortAddr shortens a bech32 address for tables: g1abc…wxyz.
func ShortAddr(addr string) string {
	if len(addr) <= 14 {
		return addr
	}
	return addr[:7] + "…" + addr[len(addr)-4:]
}

// SortAddresses returns a sorted copy of the given addresses.
func SortAddresses(addrs []string) []string {
	out := make([]string, len(addrs))
	copy(out, addrs)
	sortStrings(out)
	return out
}

// --- internals ---------------------------------------------------------

// prng is a deterministic byte stream: SHA-256(seed:counter) concatenated.
type prng struct {
	seed string
	buf  []byte
	ctr  int
}

func newPRNG(seed string) *prng {
	return &prng{seed: seed}
}

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

// sortStrings is a small insertion sort: member sets are tiny, and this keeps
// the package free of a sort import on every chain.
func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}
