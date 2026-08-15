package gsconfig

import "gno.land/p/nt/ufmt/v0"

// Sapphire GnoSwap + wrapped GNOT identifiers (evaluated 2026-08-15).
// Token ids use the GRC20 form pkg.SYMBOL.seqid.
const (
	RouterPkg   = "gno.land/r/gnoswap/router"
	StakerPkg   = "gno.land/r/gnoswap/staker"
	PositionPkg = "gno.land/r/gnoswap/position"
	GNSPkg      = "gno.land/r/gnoswap/gns"
	WugnotPkg   = "gno.land/r/gnoland/wugnot"

	GNSToken    = "gno.land/r/gnoswap/gns.GNS.0000000"
	WugnotToken = "gno.land/r/gnoland/wugnot.wugnot.0000000"

	// DefaultFee is GnoSwap's 0.30% concentrated-liquidity fee tier.
	DefaultFee uint32 = 3000
)

// Route is a single-hop router path: tokenIn:tokenOut:fee.
func Route(tokenIn, tokenOut string, fee uint32) string {
	if tokenIn == "" || tokenOut == "" {
		panic("empty token")
	}
	return tokenIn + ":" + tokenOut + ":" + ufmt.Sprintf("%d", fee)
}

// GnsToWugnot is the default harvest swap after collecting GNS emissions.
func GnsToWugnot(fee uint32) string {
	if fee == 0 {
		fee = DefaultFee
	}
	return Route(GNSToken, WugnotToken, fee)
}

// PoolKey is the canonical GnoSwap pool id (lexicographic token0:token1:fee).
func PoolKey(tokenA, tokenB string, fee uint32) string {
	if tokenA == "" || tokenB == "" {
		panic("empty token")
	}
	a, b := tokenA, tokenB
	if a > b {
		a, b = b, a
	}
	return a + ":" + b + ":" + ufmt.Sprintf("%d", fee)
}

// Config is the mutable harvest plan a strategy realm stores. Adding another
// GnoSwap pool later is SetRoute / AttachPosition, not a vault rewrite.
type Config struct {
	WantToken     string
	RewardToken   string
	Route         string
	Fee           uint32
	AmountOutMin  int64
	DeadlineSlack int64
}

// DefaultConfig harvests GNS into WUGNOT on the 0.30% tier.
func DefaultConfig() Config {
	return Config{
		WantToken:     WugnotToken,
		RewardToken:   GNSToken,
		Route:         GnsToWugnot(DefaultFee),
		Fee:           DefaultFee,
		AmountOutMin:  0,
		DeadlineSlack: 300,
	}
}
