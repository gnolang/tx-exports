package padv13

// Protocol parameters (MVP). Tunable before deploy; post-deploy treated as constants
// unless a future governance path is added with timelock.

const (
	// Token economics
	TotalSupply int64 = 1_000_000_000
	CurveSupply int64 = 800_000_000 // sold on bonding curve
	// PoolSeed is legacy: graduation seeds LP with ALL remaining tokens
	// (TotalSupply - RealSold), not a fixed 200M reserve.
	PoolSeed int64 = 200_000_000

	// Virtual constant-product seed (Pump-style).
	// Max net raise when selling full CurveSupply:
	//   R = VirtualUgnot0 * CurveSupply / (VirtualToken0 - CurveSupply)
	// Source defaults (VU0=30e6, VT0~1.073e9 -> R~87.9e6) suit local tests / 50 GNOT.
	// Sapphire prepare-v13 scales VU0 + keeps VT0 so threshold 10_000 GNOT is reachable
	// before sold-out, with ~P_curve ~ P_pool at graduate (~20% tokens -> LP).
	VirtualUgnot0 int64 = 3_500_000_000    // 30 GNOT virtual (tests)
	VirtualToken0 int64 = 1_073_000_191 // virtual token side

	// Graduation when net ugnot raised into the curve reaches this.
	// Must stay BELOW max raise from exhausting CurveSupply (see Virtual*).
	// Sapphire prepare-v13 patches to 10_000 GNOT and retunes VirtualUgnot0.
	GraduationThreshold int64 = 10_000_000_000

	// Fees: 1.20% total. Of the fee: 40% creator, 40% protocol, 20% LP/k remainder.
	FeeBPS              int64 = 120
	CreatorFeeShareBPS  int64 = 4000
	ProtocolFeeShareBPS int64 = 4000

	// Fallback create bond for unit tests / if bond realm unavailable.
	// Production pad uses createbond.CurrentBondUgnot() (see bond package).
	// Sapphire normal bond = 2 GNOT; promo ~ $20 in ugnot set on bond.StartPromo.
	CreateBondUgnot int64 = 2_000_000
	BondRefundBuyers     int   = 5
	BondRefundMinRaised int64 = 100_000_000 // >=5 GNOT raised
	BondRefundMaxHeights int64 = 100_000

	// Anti-snipe: first N heights, max cumulative tokens per address (BPS of TotalSupply).
	AntiSnipeHeights int64 = 30
	AntiSnipeMaxBuyBPS int64 = 300 // 5% per address in window

	// Status
	StatusCurve     = 0
	StatusGraduated = 1

	// Trade history ring buffer.
	MaxTradeHistory = 128
	// Trade sides stored in history
	TradeSideBuy  = 0
	TradeSideSell = 1
	TradeSideOpen = 2 // initial listing mark

	DenomUgnot = "ugnot"

	// --- Gnoswap auto-list (Sapphire) ---
	// CreatePool fee is fixed in GNS (pool.GetPoolCreationFee, typically 100e6 = 100 GNS).
	// GNOT cost of that fee MOVES with market (~10 GNOT/GNS on Sapphire probe -> ~1000 GNOT/listing).
	//
	// Funding model (price-safe):
	//   LP  = raised-sized WUGNOT (protected - never sold for fee)
	//   Fee = pre-funded GNS on pad  OR  surplus WUGNOT above raised (ExactOut -> GNS)
	// wugnot.Deposit is EOA-only - protocol wraps off-pad and transfers inventory in.
	GnoswapFeeTier     uint32 = 3000 // 0.3% meme tier
	GnoswapTickSpacing int32  = 60
	GnoswapMinTick     int32  = -887272
	GnoswapMaxTick     int32  = 887272
	// Max WUGNOT (ugnot units) allowed for ExactOut fee buy - price ceiling / slippage cap.
	// Not tied to raised/2. At ~10 GNOT/GNS, 100 GNS needs ~1006 GNOT; 5000 leaves headroom
	// if GNS becomes ~5x more expensive vs GNOT. Prefer pre-funding GNS to skip this path.
	// Sapphire prepare may raise this; for 10k GNOT raise prefer >=100 GNS on pad (no swap).
	GnoswapMaxFeeWugnot int64 = 5_000_000_000 // 5000 GNOT
)
