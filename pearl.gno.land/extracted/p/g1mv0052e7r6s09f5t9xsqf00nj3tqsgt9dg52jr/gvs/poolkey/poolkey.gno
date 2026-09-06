package poolkey

import "gno.land/p/nt/ufmt/v0"

// GnoSwap registry keys (pool-path form, no GRC20 seqid).
const (
	WugnotKey = "gno.land/r/gnoland/wugnot.wugnot"
	GnsKey    = "gno.land/r/gnoswap/gns.GNS"
	DefaultFee uint32 = 3000
)

// Spec is one concentrated-liquidity pool the factory can farm.
type Spec struct {
	Path   string
	Token0 string
	Token1 string
	Fee    uint32
	Other  string
}

// DefaultGnsWugnot is the live GNS/WUGNOT 0.30% pool.
func DefaultGnsWugnot() Spec {
	return MustWugnot(PoolPath(WugnotKey, GnsKey, DefaultFee))
}

// PoolPath is the canonical GnoSwap id (lexicographic token0:token1:fee).
func PoolPath(tokenA, tokenB string, fee uint32) string {
	if tokenA == "" || tokenB == "" {
		panic("empty token")
	}
	a, b := tokenA, tokenB
	if a > b {
		a, b = b, a
	}
	return a + ":" + b + ":" + ufmt.Sprintf("%d", fee)
}

// Route is a single-hop swap path: tokenIn:tokenOut:fee.
func Route(tokenIn, tokenOut string, fee uint32) string {
	if tokenIn == "" || tokenOut == "" {
		panic("empty token")
	}
	return tokenIn + ":" + tokenOut + ":" + ufmt.Sprintf("%d", fee)
}

// IsWugnot reports whether key is the wrapped GNOT registry id.
func IsWugnot(key string) bool {
	return key == WugnotKey
}

// Parse splits a GnoSwap pool path. Token paths must not contain ':'.
func Parse(path string) Spec {
	if path == "" {
		panic("empty pool")
	}
	if len(path) > 256 {
		panic("pool path too long")
	}
	feeAt := lastColon(path)
	if feeAt <= 0 || feeAt == len(path)-1 {
		panic("invalid pool path")
	}
	mid := lastColon(path[:feeAt])
	if mid <= 0 {
		panic("invalid pool path")
	}
	token0 := path[:mid]
	token1 := path[mid+1 : feeAt]
	fee := parseFee(path[feeAt+1:])
	if token0 == "" || token1 == "" || token0 == token1 {
		panic("invalid pool tokens")
	}
	if token0 > token1 {
		panic("pool path tokens must be sorted")
	}
	return Spec{Path: path, Token0: token0, Token1: token1, Fee: fee}
}

// MustWugnot parses path and requires exactly one side to be WUGNOT.
func MustWugnot(path string) Spec {
	s := Parse(path)
	w0 := IsWugnot(s.Token0)
	w1 := IsWugnot(s.Token1)
	if w0 == w1 {
		panic("pool must be a WUGNOT pair")
	}
	if w0 {
		s.Other = s.Token1
	} else {
		s.Other = s.Token0
	}
	return s
}

func lastColon(s string) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == ':' {
			return i
		}
	}
	return -1
}

func parseFee(s string) uint32 {
	if s == "" {
		panic("empty fee")
	}
	var n uint64
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			panic("invalid fee")
		}
		n = n*10 + uint64(c-'0')
		if n > 1_000_000 {
			panic("fee too large")
		}
	}
	if n == 0 {
		panic("fee must be positive")
	}
	return uint32(n)
}
