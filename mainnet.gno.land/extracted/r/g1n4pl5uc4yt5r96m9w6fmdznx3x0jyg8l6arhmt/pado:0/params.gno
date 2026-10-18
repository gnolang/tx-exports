package pado

// Curve shape matches padv3 so a 300_000 GNOT raise uses the same virtual seed.
// VirtualUgnot0 is not a constant: Create scales it so the chosen raise is what
// selling CurveSupply locks.
//
//	vu0 = raise * (VirtualToken0 - CurveSupply) / CurveSupply
//	reachable = vu0 * CurveSupply / (VirtualToken0 - CurveSupply)
//
// There is no trade fee. Buy spends the full quote. Sell returns the full quote
// that this launch actually holds.

const (
	TotalSupply   int64 = 1_000_000_000
	CurveSupply   int64 = 800_000_000
	VirtualToken0 int64 = 1_073_000_191

	// Creator-chosen raise, in ugnot. 1 GNOT = 1_000_000 ugnot.
	MinRaiseUgnot int64 = 1_000_000             // 1 GNOT
	MaxRaiseUgnot int64 = 1_000_000_000_000_000 // 1_000_000 GNOT

	// Opening window only. This is a size cap, not a fee.
	AntiSnipeHeights   int64 = 20
	AntiSnipeMaxBuyBPS int64 = 500 // 5% of TotalSupply per address

	MaxURILen = 256

	StatusCurve     = 0
	StatusGraduated = 1

	DenomUgnot = "ugnot"
)
