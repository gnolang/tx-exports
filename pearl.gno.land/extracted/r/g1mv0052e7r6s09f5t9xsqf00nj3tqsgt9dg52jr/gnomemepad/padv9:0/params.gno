package padv9

// Protocol parameters (MVP). Tunable before deploy; post-deploy treated as constants
// unless a future governance path is added with timelock.

const (
	// Token economics
	TotalSupply int64 = 1_000_000_000
	CurveSupply int64 = 800_000_000 // sold on bonding curve
	// PoolSeed is legacy: graduation seeds LP with ALL remaining tokens
	// (TotalSupply - RealSold), not a fixed 200M reserve.
	PoolSeed int64 = 200_000_000

	// Virtual constant-product seed (Pump-style)
	VirtualUgnot0 int64 = 30_000_000    // 30 GNOT virtual
	VirtualToken0 int64 = 1_073_000_191 // virtual token side

	// Graduation when net ugnot raised into the curve reaches this.
	// Sapphire deploy patches to 100 GNOT.
	// Keep below the ugnot needed to exhaust CurveSupply on the virtual CPMM.
	GraduationThreshold int64 = 100_000_000

	// Fees: 1.20% total. Of the fee: 40% creator, 40% protocol, 20% LP/k remainder.
	FeeBPS              int64 = 120
	CreatorFeeShareBPS  int64 = 4000
	ProtocolFeeShareBPS int64 = 4000

	// Fallback create bond for unit tests / if bond realm unavailable.
	// Production pad uses createbond.CurrentBondUgnot() (see bond package).
	// Sapphire normal bond = 2 GNOT; promo â‰ˆ $20 in ugnot set on bond.StartPromo.
	CreateBondUgnot int64 = 2_000_000
	BondRefundBuyers     int   = 5
	BondRefundMinRaised  int64 = 10_000_000 // â‰¥5 GNOT raised
	BondRefundMaxHeights int64 = 100_000

	// Anti-snipe: first N heights, max cumulative tokens per address (BPS of TotalSupply).
	AntiSnipeHeights   int64 = 30
	AntiSnipeMaxBuyBPS int64 = 300 // 5% per address in window

	// Status
	StatusCurve     = 0
	StatusGraduated = 1

	// Trade history ring buffer.
	MaxTradeHistory = 256
	// Trade sides stored in history
	TradeSideBuy  = 0
	TradeSideSell = 1
	TradeSideOpen = 2 // initial listing mark

	DenomUgnot = "ugnot"

	// --- Gnoswap auto-list (Sapphire) ---
	// CreatePool fee is fixed in GNS (pool.GetPoolCreationFee, typically 100e6 = 100 GNS).
	// GNOT cost of that fee MOVES with market (~10 GNOT/GNS on Sapphire probe â†’ ~1000 GNOT/listing).
	//
	// Funding model (price-safe):
	//   LP  = raised-sized WUGNOT (protected â€” never sold for fee)
	//   Fee = pre-funded GNS on pad  OR  surplus WUGNOT above raised (ExactOut â†’ GNS)
	// wugnot.Deposit is EOA-only â€” protocol wraps off-pad and transfers inventory in.
	GnoswapFeeTier     uint32 = 3000 // 0.3% meme tier
	GnoswapTickSpacing int32  = 60
	GnoswapMinTick     int32  = -887272
	GnoswapMaxTick     int32  = 887272
	// Max WUGNOT (ugnot units) allowed for ExactOut fee buy â€” price ceiling / slippage cap.
	// Not tied to raised/2. At ~10 GNOT/GNS, 100 GNS needs ~1006 GNOT; 5000 leaves headroom
	// if GNS becomes ~5Ã— more expensive vs GNOT. Prefer pre-funding GNS to skip this path.
	GnoswapMaxFeeWugnot int64 = 5_000_000_000 // 5000 GNOT
)
