// Package signals implements consensus-safe, deterministic fixed-point statistical
// assurance primitives in pure Gno (zero floating-point operations).
//
// All values use fixed-point micro-units (Scale = 1_000_000, i.e. 1.0 == 1_000_000).
// Every primitive can emit a canonically encoded SignalEvidence record whose RFC 6962
// leaf hash chains directly into gno.land/p/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/assurance accumulators.
package signals

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
)

const (
	// Scale is 1.0 in fixed-point micro-units (6 decimal digits).
	Scale int64 = 1000000
	// MADScale is 1.4826 * Scale, making MAD a consistent Gaussian sigma estimator.
	MADScale int64 = 1482600
	// MinSDFixed prevents division by zero on flat telemetry baselines (1e-6).
	MinSDFixed int64 = 1
)

// Abs64 returns |x| for int64 (safe for normal fixed-point ranges).
func Abs64(x int64) int64 {
	if x < 0 {
		return -x
	}
	return x
}

// MulFixed computes round-toward-zero (a * b) / Scale using split-word arithmetic
// to avoid intermediate int64 overflow for large fixed-point operands.
func MulFixed(a, b int64) int64 {
	neg := false
	var ua, ub uint64
	if a < 0 {
		neg = !neg
		ua = uint64(-a)
	} else {
		ua = uint64(a)
	}
	if b < 0 {
		neg = !neg
		ub = uint64(-b)
	} else {
		ub = uint64(b)
	}
	s := uint64(Scale)
	ah, al := ua/s, ua%s
	bh, bl := ub/s, ub%s
	// (ah*s + al)*(bh*s + bl) / s = ah*bh*s + ah*bl + al*bh + (al*bl)/s
	res := ah*bh*s + ah*bl + al*bh + (al*bl)/s
	if neg {
		return -int64(res)
	}
	return int64(res)
}

// DivFixed computes (a * Scale) / b with overflow-safe splitting on a.
func DivFixed(a, b int64) int64 {
	if b == 0 {
		panic("signals: division by zero")
	}
	neg := false
	var ua, ub uint64
	if a < 0 {
		neg = !neg
		ua = uint64(-a)
	} else {
		ua = uint64(a)
	}
	if b < 0 {
		neg = !neg
		ub = uint64(-b)
	} else {
		ub = uint64(b)
	}
	s := uint64(Scale)
	// Write ua = q*ub + r, then (ua*s)/ub = q*s + (r*s)/ub.
	q := ua / ub
	r := ua % ub
	var frac uint64
	if r <= (^uint64(0))/s {
		frac = (r * s) / ub
	} else {
		// Fallback for huge remainders (ub > ~1.8e13): scale down both safely.
		frac = ((r / 1000) * s) / (ub / 1000)
	}
	res := q*s + frac
	if neg {
		return -int64(res)
	}
	return int64(res)
}

// ISqrt64 returns floor(sqrt(n)) deterministically using Newton's method.
func ISqrt64(n uint64) uint64 {
	if n < 2 {
		return n
	}
	// Initial power-of-two upper estimate.
	x := uint64(1)
	tmp := n
	for tmp > 0 {
		tmp >>= 2
		x <<= 1
	}
	for {
		next := (x + n/x) >> 1
		if next >= x {
			return x
		}
		x = next
	}
}

// SqrtFixed computes sqrt(xFixed) in fixed-point Scale units (xFixed >= 0).
// sqrt(x * Scale) * sqrt(Scale) == sqrt(xFixed * Scale).
func SqrtFixed(xFixed int64) int64 {
	if xFixed <= 0 {
		return 0
	}
	u := uint64(xFixed)
	s := uint64(Scale)
	if u <= (^uint64(0))/s {
		return int64(ISqrt64(u * s))
	}
	// For very large xFixed (> 1.8e13), sqrt(u) * sqrt(Scale) = sqrt(u) * 1000.
	return int64(ISqrt64(u) * 1000)
}

// MedianFixed computes the exact deterministic median of a non-empty int64 slice.
func MedianFixed(vals []int64) int64 {
	n := len(vals)
	if n == 0 {
		return 0
	}
	cp := make([]int64, n)
	copy(cp, vals)
	for i := 1; i < n; i++ {
		key := cp[i]
		j := i - 1
		for j >= 0 && cp[j] > key {
			cp[j+1] = cp[j]
			j--
		}
		cp[j+1] = key
	}
	mid := n / 2
	if n%2 == 1 {
		return cp[mid]
	}
	// Overflow-safe average of two middle elements.
	a, b := cp[mid-1], cp[mid]
	return a + (b-a)/2
}

// SignalEvidence is the tamper-evident audit record emitted by any deterministic primitive.
type SignalEvidence struct {
	Primitive    string
	Version      string
	ParamsDigest [32]byte
	InputDigest  [32]byte
	OutputFixed  int64
	Alarm        bool
	Detail       string
}

const (
	DomainSignalEvidence = "arobi-signal-evidence-v1"
	SignalEncodingVer    = uint8(1)
)

// Encode serializes SignalEvidence into canonical big-endian bytes.
func (e SignalEvidence) Encode() []byte {
	out := make([]byte, 0, 160)
	out = appendStr(out, DomainSignalEvidence)
	out = append(out, SignalEncodingVer)
	out = appendStr(out, e.Primitive)
	out = appendStr(out, e.Version)
	out = append(out, e.ParamsDigest[:]...)
	out = append(out, e.InputDigest[:]...)
	out = binary.BigEndian.AppendUint64(out, uint64(e.OutputFixed))
	if e.Alarm {
		out = append(out, 1)
	} else {
		out = append(out, 0)
	}
	out = appendStr(out, e.Detail)
	return out
}

// LeafHash computes the RFC 6962 leaf hash SHA-256(0x00 || Encode()).
func (e SignalEvidence) LeafHash() [32]byte {
	raw := e.Encode()
	buf := make([]byte, 0, 1+len(raw))
	buf = append(buf, 0x00)
	buf = append(buf, raw...)
	return sha256.Sum256(buf)
}

// Hex formats a 32-byte digest as 64 lowercase hex chars.
func Hex(d [32]byte) string {
	return hex.EncodeToString(d[:])
}

func hashInt64s(domain string, vals ...int64) [32]byte {
	buf := make([]byte, 0, len(domain)+8+len(vals)*8)
	buf = appendStr(buf, domain)
	for _, v := range vals {
		buf = binary.BigEndian.AppendUint64(buf, uint64(v))
	}
	return sha256.Sum256(buf)
}

func appendStr(out []byte, s string) []byte {
	out = binary.BigEndian.AppendUint32(out, uint32(len(s)))
	return append(out, []byte(s)...)
}
