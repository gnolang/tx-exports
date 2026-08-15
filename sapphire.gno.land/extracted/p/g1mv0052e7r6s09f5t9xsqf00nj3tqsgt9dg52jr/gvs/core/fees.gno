package core

// FeeConfig is the harvest split. Sum of bps must stay below BPSDenom so
// depositors always keep a remainder.
type FeeConfig struct {
	CallerBPS   int64
	ProtocolBPS int64
}

// DefaultFees is 0.5% caller bounty + 5% protocol, matching Yield Yak's
// typical harvest-fee band (no deposit/withdraw fee).
func DefaultFees() FeeConfig {
	return FeeConfig{CallerBPS: 50, ProtocolBPS: 500}
}

// Validate panics if the fee pair is unusable.
func (f FeeConfig) Validate() {
	if f.CallerBPS < 0 || f.ProtocolBPS < 0 {
		panic("negative fee")
	}
	sum, ok := add64(f.CallerBPS, f.ProtocolBPS)
	if !ok || sum >= BPSDenom {
		panic("fees must leave a remainder for depositors")
	}
}

// SplitHarvest divides `profit` into caller bounty, protocol cut, and the
// amount that compounds. Dust from integer division stays with compound.
func SplitHarvest(profit int64, fees FeeConfig) (caller, protocol, compound int64) {
	if profit <= 0 {
		panic("profit must be positive")
	}
	fees.Validate()
	caller = mulDiv(profit, fees.CallerBPS, BPSDenom)
	protocol = mulDiv(profit, fees.ProtocolBPS, BPSDenom)
	used, ok := add64(caller, protocol)
	if !ok || used > profit {
		panic("fee overflow")
	}
	compound = profit - used
	return
}

// ReinvestGuard stops empty or rapid harvests (Yield Yak's min-reward + cooldown).
type ReinvestGuard struct {
	MinProfit    int64
	MinInterval  int64
	LastUnix     int64
	LastHeight   int64
}

// DefaultGuard requires at least 1 unit of profit and a 1-block gap.
func DefaultGuard() ReinvestGuard {
	return ReinvestGuard{MinProfit: 1, MinInterval: 1}
}

// Check panics when this harvest should not run.
func (g ReinvestGuard) Check(profit, nowUnix, height int64) {
	if profit < g.MinProfit {
		panic("profit below minimum")
	}
	if g.MinInterval <= 0 {
		return
	}
	if g.LastHeight != 0 && height <= g.LastHeight {
		panic("reinvest too soon")
	}
	if g.LastUnix != 0 && nowUnix > 0 && nowUnix-g.LastUnix < g.MinInterval {
		panic("reinvest too soon")
	}
}
